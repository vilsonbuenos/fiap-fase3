package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
	"github.com/joho/godotenv"
	"github.com/redis/go-redis/extra/redisotel/v9"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
)

// App struct para injeção de dependência
type App struct {
	RedisClient         *redis.Client
	SqsSvc              *sqs.SQS
	SqsQueueURL         string
	HttpClient          *http.Client
	FlagServiceURL      string
	TargetingServiceURL string

	// Métricas de negócio exportadas via OTel (viram séries no Prometheus)
	CacheRequests metric.Int64Counter
	Decisions     metric.Int64Counter
}

func main() {
	_ = godotenv.Load() // Carrega .env para dev local

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdownTelemetry, err := setupTelemetry(ctx, "evaluation-service")
	if err != nil {
		log.Printf("OpenTelemetry não inicializado: %v", err)
	}

	// --- Configuração ---
	port := os.Getenv("PORT")
	if port == "" {
		port = "8004"
	}

	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		log.Fatal("REDIS_URL deve ser definida (ex: redis://localhost:6379)")
	}

	flagSvcURL := os.Getenv("FLAG_SERVICE_URL")
	if flagSvcURL == "" {
		log.Fatal("FLAG_SERVICE_URL deve ser definida")
	}

	targetingSvcURL := os.Getenv("TARGETING_SERVICE_URL")
	if targetingSvcURL == "" {
		log.Fatal("TARGETING_SERVICE_URL deve ser definida")
	}

	// SQS é opcional no dev local, mas obrigatório em prod
	sqsQueueURL := os.Getenv("AWS_SQS_URL")
	awsRegion := os.Getenv("AWS_REGION")
	if sqsQueueURL == "" {
		log.Println("Atenção: AWS_SQS_URL não definida. Eventos não serão enviados.")
	}
	if awsRegion == "" && sqsQueueURL != "" {
		log.Fatal("AWS_REGION deve ser definida para usar SQS")
	}

	// --- Inicializa Clientes ---

	// Cliente Redis (rediss:// habilita TLS, exigido pelo ElastiCache)
	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		log.Fatalf("Não foi possível parsear a URL do Redis: %v", err)
	}
	rdb := redis.NewClient(opt)
	if err := redisotel.InstrumentTracing(rdb); err != nil {
		log.Printf("Não foi possível instrumentar traces do Redis: %v", err)
	}
	if err := redisotel.InstrumentMetrics(rdb); err != nil {
		log.Printf("Não foi possível instrumentar métricas do Redis: %v", err)
	}
	if _, err := rdb.Ping(ctx).Result(); err != nil {
		log.Fatalf("Não foi possível conectar ao Redis: %v", err)
	}
	log.Println("Conectado ao Redis com sucesso!")

	// Cliente SQS (AWS SDK)
	var sqsSvc *sqs.SQS
	if sqsQueueURL != "" {
		sess, err := session.NewSession(&aws.Config{Region: aws.String(awsRegion)})
		if err != nil {
			log.Fatalf("Não foi possível criar sessão AWS: %v", err)
		}
		sqsSvc = sqs.New(sess)
		log.Println("Cliente SQS inicializado com sucesso.")
	}

	// Cliente HTTP (com timeout). O transport do otelhttp cria um span de
	// cliente por chamada e injeta o header traceparent, ligando o trace do
	// evaluation ao do flag-service e do targeting-service.
	httpClient := &http.Client{
		Timeout:   5 * time.Second,
		Transport: otelhttp.NewTransport(http.DefaultTransport),
	}

	meter := otel.Meter("evaluation-service")
	cacheRequests, err := meter.Int64Counter("togglemaster.evaluation.cache",
		metric.WithDescription("Consultas ao cache de regras no Redis, por resultado (hit/miss)"),
		metric.WithUnit("{request}"))
	if err != nil {
		log.Printf("Erro ao criar métrica de cache: %v", err)
	}
	decisions, err := meter.Int64Counter("togglemaster.evaluation.decisions",
		metric.WithDescription("Decisões de avaliação por flag e resultado"),
		metric.WithUnit("{decision}"))
	if err != nil {
		log.Printf("Erro ao criar métrica de decisões: %v", err)
	}

	// Cria a instância da App
	app := &App{
		RedisClient:         rdb,
		SqsSvc:              sqsSvc,
		SqsQueueURL:         sqsQueueURL,
		HttpClient:          httpClient,
		FlagServiceURL:      flagSvcURL,
		TargetingServiceURL: targetingSvcURL,
		CacheRequests:       cacheRequests,
		Decisions:           decisions,
	}

	// --- Rotas ---
	mux := http.NewServeMux()
	mux.HandleFunc("/evaluation/health", app.healthHandler)
	mux.HandleFunc("/evaluation/evaluate", app.evaluationHandler)

	handler := otelhttp.NewHandler(mux, "evaluation-service",
		otelhttp.WithSpanNameFormatter(httpSpanName),
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/evaluation/health" }),
	)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("Serviço de Avaliação (Go) rodando na porta %s", port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	<-ctx.Done()
	log.Println("Encerrando: aguardando requisições em andamento e enviando telemetria pendente...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("Erro no shutdown do servidor HTTP: %v", err)
	}
	if shutdownTelemetry != nil {
		if err := shutdownTelemetry(shutdownCtx); err != nil {
			log.Printf("Erro no flush da telemetria: %v", err)
		}
	}
}
