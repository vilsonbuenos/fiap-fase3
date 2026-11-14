package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// setupTelemetry registra os providers globais de traces e métricas,
// exportando via OTLP/HTTP para o OTel Collector. Endpoint, service.name e
// atributos extras vêm das variáveis OTEL_* padrão; OTEL_SDK_DISABLED=true
// desliga a exportação. A função retornada faz o flush no shutdown.
func setupTelemetry(ctx context.Context, serviceName string) (func(context.Context) error, error) {
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	noop := func(context.Context) error { return nil }
	if strings.EqualFold(os.Getenv("OTEL_SDK_DISABLED"), "true") {
		return noop, nil
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(attribute.String("service.name", serviceName)),
		resource.WithFromEnv(),
		resource.WithTelemetrySDK(),
		resource.WithHost(),
	)
	if err != nil {
		log.Printf("OpenTelemetry: resource incompleto: %v", err)
	}
	if res == nil {
		res = resource.Default()
	}

	traceExporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return noop, err
	}
	tracerProvider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tracerProvider)

	metricExporter, err := otlpmetrichttp.New(ctx)
	if err != nil {
		return tracerProvider.Shutdown, err
	}
	meterProvider := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter, sdkmetric.WithInterval(15*time.Second))),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(meterProvider)

	return func(ctx context.Context) error {
		return errors.Join(tracerProvider.Shutdown(ctx), meterProvider.Shutdown(ctx))
	}, nil
}

// httpSpanName nomeia o span do servidor como "MÉTODO /rota". O otelhttp chama
// de novo depois do ServeMux, quando r.Pattern já está preenchido.
func httpSpanName(_ string, r *http.Request) string {
	if r.Pattern != "" {
		return r.Method + " " + r.Pattern
	}
	return r.Method
}

// logf escreve no log padrão prefixando trace_id/span_id quando há um span
// ativo no contexto. O otel-agent extrai esses campos e o Loki permite buscar
// todas as linhas de log de um trace.
func logf(ctx context.Context, format string, args ...any) {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		log.Printf(format, args...)
		return
	}
	log.Printf("trace_id=%s span_id=%s "+format, append([]any{sc.TraceID().String(), sc.SpanID().String()}, args...)...)
}
