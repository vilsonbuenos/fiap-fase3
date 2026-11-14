package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/XSAM/otelsql"
	_ "github.com/jackc/pgx/v4/stdlib"
	"github.com/joho/godotenv"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
)

// App struct (para injeção de dependência)
type App struct {
	DB        *sql.DB
	MasterKey string
}

func main() {
	// Carrega o .env para desenvolvimento local. Em produção, isso não fará nada.
	_ = godotenv.Load()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdownTelemetry, err := setupTelemetry(ctx, "auth-service")
	if err != nil {
		log.Printf("OpenTelemetry não inicializado: %v", err)
	}

	// --- Configuração ---
	port := os.Getenv("PORT")
	if port == "" {
		port = "8001" // Porta padrão
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL deve ser definida")
	}

	masterKey := os.Getenv("MASTER_KEY")
	if masterKey == "" {
		log.Fatal("MASTER_KEY deve ser definida")
	}

	// --- Conexão com o Banco ---
	db, err := connectDB(ctx, databaseURL)
	if err != nil {
		log.Fatalf("Não foi possível conectar ao banco de dados: %v", err)
	}
	defer db.Close()

	app := &App{
		DB:        db,
		MasterKey: masterKey,
	}

	// --- Rotas da API ---
	mux := http.NewServeMux()
	mux.HandleFunc("/auth/health", app.healthHandler)

	// Endpoint público para validar uma chave
	mux.HandleFunc("/auth/validate", app.validateKeyHandler)

	// Endpoints de "admin" para criar/gerenciar chaves
	// Eles são protegidos pelo middleware de autenticação
	mux.Handle("/auth/admin/keys", app.masterKeyAuthMiddleware(http.HandlerFunc(app.createKeyHandler)))

	// Cada requisição vira um span de servidor (contexto W3C propagado pelo
	// chamador). Health checks do kubelet/ALB ficam fora para não poluir.
	handler := otelhttp.NewHandler(mux, "auth-service",
		otelhttp.WithSpanNameFormatter(httpSpanName),
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/auth/health" }),
	)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("Serviço de Autenticação (Go) rodando na porta %s", port)
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

// connectDB inicializa e testa a conexão com o PostgreSQL. O driver é
// envolvido pelo otelsql: cada query vira um span filho da requisição HTTP e
// as estatísticas do pool viram métricas.
func connectDB(ctx context.Context, databaseURL string) (*sql.DB, error) {
	dbAttrs := otelsql.WithAttributes(
		attribute.String("db.system", "postgresql"),
		attribute.String("db.system.name", "postgresql"),
	)

	db, err := otelsql.Open("pgx", databaseURL, dbAttrs,
		otelsql.WithSpanOptions(otelsql.SpanOptions{
			OmitConnResetSession: true,
			OmitConnectorConnect: true,
			OmitRows:             true,
			DisableErrSkip:       true,
		}),
	)
	if err != nil {
		return nil, err
	}

	if err = db.PingContext(ctx); err != nil {
		return nil, err
	}

	if _, err := otelsql.RegisterDBStatsMetrics(db, dbAttrs); err != nil {
		log.Printf("Não foi possível registrar métricas do pool do banco: %v", err)
	}

	log.Println("Conectado ao PostgreSQL com sucesso!")
	return db, nil
}
