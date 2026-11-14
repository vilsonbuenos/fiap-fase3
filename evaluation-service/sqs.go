package main

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/sqs"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

// Evento que será enviado para a fila
type EvaluationEvent struct {
	UserID    string    `json:"user_id"`
	FlagName  string    `json:"flag_name"`
	Result    bool      `json:"result"`
	Timestamp time.Time `json:"timestamp"`
}

var tracer = otel.Tracer("evaluation-service")

// sendEvaluationEvent envia um evento para a fila SQS. O contexto do trace
// (traceparent) vai nos MessageAttributes, e o analytics-service continua o
// mesmo trace ao consumir a mensagem.
func (a *App) sendEvaluationEvent(ctx context.Context, userID, flagName string, result bool) {
	// Se a URL da fila não foi configurada, apenas loga localmente e sai.
	if a.SqsSvc == nil || a.SqsQueueURL == "" {
		logf(ctx, "[SQS_DISABLED] Evento: User '%s', Flag '%s', Result '%t'", userID, flagName, result)
		return
	}

	queueName := a.SqsQueueURL[strings.LastIndex(a.SqsQueueURL, "/")+1:]
	ctx, span := tracer.Start(ctx, queueName+" send",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "aws_sqs"),
			attribute.String("messaging.operation.type", "send"),
			attribute.String("messaging.destination.name", queueName),
		),
	)
	defer span.End()

	event := EvaluationEvent{
		UserID:    userID,
		FlagName:  flagName,
		Result:    result,
		Timestamp: time.Now().UTC(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "erro ao serializar evento")
		logf(ctx, "Erro ao serializar evento SQS: %v", err)
		return
	}

	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	attrs := make(map[string]*sqs.MessageAttributeValue, len(carrier))
	for k, v := range carrier {
		if v == "" { // SQS rejeita atributo com valor vazio
			continue
		}
		attrs[k] = &sqs.MessageAttributeValue{DataType: aws.String("String"), StringValue: aws.String(v)}
	}

	// Envia a mensagem
	out, err := a.SqsSvc.SendMessageWithContext(ctx, &sqs.SendMessageInput{
		MessageBody:       aws.String(string(body)),
		QueueUrl:          aws.String(a.SqsQueueURL),
		MessageAttributes: attrs,
	})

	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "erro ao enviar para o SQS")
		logf(ctx, "Erro ao enviar mensagem para SQS: %v", err)
		return
	}
	span.SetAttributes(attribute.String("messaging.message.id", aws.StringValue(out.MessageId)))
	logf(ctx, "Evento de avaliação enviado para SQS (Flag: %s)", flagName)
}
