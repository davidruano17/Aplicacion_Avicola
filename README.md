# AVISENA COL — Documentación de Base de Datos (PostgreSQL Multi-Tenant)

Migración y rediseño de [SCRIPT_AVISENACOL_DB.sql](./SCRIPT_AVISENACOL_DB.sql) (MySQL mono-cliente) hacia [SCRIPT_AVISENACOL_POSTGRES_MULTITENANT.sql](./SCRIPT_AVISENACOL_POSTGRES_MULTITENANT.sql) (PostgreSQL 15+ Multi-Tenant).

---

## 1. Cambios Principales

- **Motor:** MySQL → **PostgreSQL 15+** (esquema dedicado `avisena`).
- **Modelo Multi-Tenant:** Jerarquía `tenants` → `granjas` → `galpones` → `lotes_aves` con `tenant_id` obligatorio en todas las tablas.
- **Separación de Dominio:** Se separa `galpones` (infraestructura física) de `lotes_aves` (ciclo biológico de ~80–100 semanas) para conservar históricos entre parvadas.
- **Módulos Completos del Frontend:** Se añaden tablas faltantes para `configuraciones_usuario`, `inventario_huevos_galpon`, `clasificacion_huevos_detalle`, `finanzas_venta_huevos_detalle` (ventas multi-clasificadas y gasto asociado del 10%) y `audit_logs`.
- **Curvas Genéticas:** Se normalizan en `lineas_geneticas` y `curvas_referencia_genetica` (Hy-Line Brown, Lohmann Brown, Dekalb, ISA Brown, Babcock).

---

## 2. Mejoras Implementadas

- **Aislamiento Estricto (Zero Cross-Tenant):**
  - **Row-Level Security (RLS)** en las 18 tablas operativas vía `avisena.current_tenant_id()`.
  - **Foreign Keys compuestas con `tenant_id`** para impedir referencias cruzadas entre clientes a nivel de motor.
- **Escalabilidad (Millones de Registros):**
  - Claves primarias `BIGINT GENERATED ALWAYS AS IDENTITY` en tablas transaccionales.
  - Índices B-Tree compuestos liderados por `tenant_id` e índices parciales (ej. `estado_clasificacion = 'PENDIENTE'`, `deleted_at IS NULL`).
  - Índices **BRIN** sobre fechas (`produccion_huevos`, `alimentacion_aves`, `finanzas_transacciones`, `audit_logs`).
- **Integridad Zootécnica y Contable:**
  - `aves_presentes_dia` como snapshot histórico en producción y alimentación (evita distorsión del `% postura`).
  - **Triggers:** Descuento/reversión automática de `aves_actuales` al registrar mortalidad (+ alerta crítica si supera el 2%), actualización de stock/sobrantes de huevos por calibre y cambio automático de producción a `CLASIFICADO`.
  - **Vista `vw_fcr_mensual_lote`:** Cálculo directo en BD de conversión alimenticia ($CA = K / D$).

---

## 3. Ideas y Evolución Posterior

1. **Particionamiento Declarativo (Range by Year/Month):** Particionar `produccion_huevos`, `finanzas_transacciones` y `audit_logs` por fecha cuando superen ~10–20M de filas por tabla.
2. **Vistas Materializadas para Dashboard:** Crear `mv_resumen_dashboard_tenant` con refresco programado (`pg_cron`) para métricas instantáneas sin recalcular agregados.
3. **Inventario de Alimento e Insumos:** Agregar tablas de bodega (`bodega_insumos`, `movimientos_bodega`) para controlar compras vs. consumo diario en `alimentacion_aves`.
4. **Auditoría Automática por Trigger:** Conectar un trigger genérico hacia `audit_logs` en tablas críticas (`finanzas_transacciones`, `mortalidad_aves`, `lotes_aves`).
5. **Conexión ORM + Pooler:** Integrar **Drizzle ORM** o **Prisma** con **PgBouncer** (modo `transaction`) ejecutando `SET LOCAL app.current_tenant_id` por petición.
6. **Backups y Retención:** Configurar PITR (Point-in-Time Recovery) y archivado de lotes cerrados antiguos.
