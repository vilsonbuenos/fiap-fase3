"""OpenTelemetry do targeting-service: traces + métricas via OTLP/HTTP para o OTel Collector.

Endpoint, service.name e atributos extras vêm das variáveis OTEL_* padrão
(OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES).
OTEL_SDK_DISABLED=true desliga tudo (útil para rodar local sem collector).
"""
import logging
import os

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

SERVICE_NAME = "targeting-service"

# trace_id/span_id em cada linha: o otel-agent extrai e o Loki indexa como
# structured metadata, ligando o log ao trace no Datadog.
LOG_FORMAT = "%(asctime)s %(levelname)s [%(name)s] trace_id=%(otelTraceID)s span_id=%(otelSpanID)s %(message)s"


def _enabled():
    return os.getenv("OTEL_SDK_DISABLED", "false").lower() != "true"


def setup_telemetry():
    """Chamar antes de abrir conexões com o banco (o driver é instrumentado aqui)."""
    if not _enabled():
        return

    attributes = {} if os.getenv("OTEL_SERVICE_NAME") else {"service.name": SERVICE_NAME}
    resource = Resource.create(attributes)

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(tracer_provider)

    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(),
        export_interval_millis=int(os.getenv("OTEL_METRIC_EXPORT_INTERVAL", "15000")),
    )
    metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[reader]))

    # Só injeta otelTraceID/otelSpanID nos registros. O handler que exporta log
    # via OTLP fica desligado: os logs chegam ao Loki pelo stdout (otel-agent),
    # e mandar pelos dois caminhos duplicaria cada linha.
    LoggingInstrumentor().instrument(inject_trace_context=True, enable_log_auto_instrumentation=False)
    formatter = logging.Formatter(LOG_FORMAT)
    for handler in logging.getLogger().handlers:
        handler.setFormatter(formatter)

    # Chamadas ao auth-service (/validate) viram spans de cliente com traceparent
    RequestsInstrumentor().instrument()
    # Cada query no PostgreSQL vira um span filho da requisição
    Psycopg2Instrumentor().instrument(skip_dep_check=True)


def instrument_app(app):
    """Span de servidor por requisição; health checks ficam de fora."""
    if not _enabled():
        return
    FlaskInstrumentor().instrument_app(app, excluded_urls="health")
