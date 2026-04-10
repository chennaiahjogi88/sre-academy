'use strict';
// ── OpenTelemetry tracing ─────────────────────────────────────────────────────
// This file MUST be required before any other module.
// In production it is loaded via: node --require ./src/tracing.js src/index.js
//
// Traces are exported to Jaeger via OTLP HTTP.
// Configure the endpoint with:
//   OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger-service.monitoring.svc.cluster.local:4318
// ─────────────────────────────────────────────────────────────────────────────

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');

const OTLP_ENDPOINT = process.env.OTEL_EXPORTER_OTLP_ENDPOINT;

// If no endpoint is configured, tracing is a no-op (safe in local dev)
if (!OTLP_ENDPOINT) {
  console.log('[tracing] OTEL_EXPORTER_OTLP_ENDPOINT not set — tracing disabled');
  module.exports = {};
  return;
}

const sdk = new NodeSDK({
  serviceName: process.env.OTEL_SERVICE_NAME || 'sre-platform-backend',
  traceExporter: new OTLPTraceExporter({
    url: `${OTLP_ENDPOINT}/v1/traces`,
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      // Disable fs instrumentation — too noisy, not useful for students
      '@opentelemetry/instrumentation-fs': { enabled: false },
      // Auto-instruments: express, pg, http, socket.io, etc.
      '@opentelemetry/instrumentation-express': { enabled: true },
      '@opentelemetry/instrumentation-http': { enabled: true },
      '@opentelemetry/instrumentation-pg': { enabled: true },
    }),
  ],
});

sdk.start();
console.log(`[tracing] OpenTelemetry initialized → ${OTLP_ENDPOINT}`);

process.on('SIGTERM', () => {
  sdk.shutdown()
    .then(() => console.log('[tracing] SDK shut down cleanly'))
    .finally(() => process.exit(0));
});

module.exports = { sdk };
