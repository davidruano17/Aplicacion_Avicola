-- ============================================================================
-- AVISENA COL - ARQUITECTURA DE BASE DE DATOS MULTI-TENANT (POSTGRESQL 15+)
-- Especializada en Avicultura de Postura (Gallinas Ponedoras) y Alta Escala
-- ============================================================================
-- Características de Ingeniería:
-- 1. Multi-Tenancy (Shared Database, Shared Schema) con Row-Level Security (RLS).
-- 2. Separación estricta de dominio: Tenant -> Granja -> Galpón (Físico) -> Lote (Parvada).
-- 3. 100% compatible con todos los módulos actuales del frontend Next.js:
--    - Usuarios, Roles, Perfil y Configuración (avisena_settings).
--    - Galpones y Lotes con curvas genéticas (Hy-Line, Lohmann, ISA, Dekalb, Babcock).
--    - Producción diaria por jornada + snapshot de aves + estado pendiente de clasificar.
--    - Alimentación diaria y cálculo de Conversión Alimenticia (FCR / ICA).
--    - Clasificación por calibres (C, B, A, AA, AAA, Jumbo), control de sobrantes (<30 uds)
--      e inventario vivo de panales por galpón.
--    - Sanidad: Mortalidad (con descuento transaccional de aves), Morbilidad y Tratamientos.
--    - Finanzas: Ingresos/Gastos, Ventas Multi-Clasificadas y Gastos Asociados (10% empaque).
--    - Notificaciones por severidad (critical, warning, success, info) y Auditoría.
-- 4. Preparada para millones de registros: Índices compuestos (tenant_id + fecha),
--    índices BRIN para series temporales, Triggers de integridad y Vistas Analíticas.
-- ============================================================================

BEGIN;

-- Extensiones requeridas
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "citext";

-- Esquema dedicado de aplicación
CREATE SCHEMA IF NOT EXISTS avisena;
SET search_path TO avisena, public;

-- ============================================================================
-- 0. FUNCIONES DE UTILIDAD, AUDITORÍA Y CONTEXTO MULTI-TENANT (RLS)
-- ============================================================================

-- Obtiene el tenant_id activo de la sesión de base de datos:
-- En el backend (Prisma/Drizzle/pg), al iniciar cada transacción se ejecuta:
-- SET LOCAL app.current_tenant_id = 'uuid-del-tenant';
CREATE OR REPLACE FUNCTION avisena.current_tenant_id()
RETURNS UUID
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
$$;

-- Trigger genérico para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION avisena.fn_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

-- ============================================================================
-- 1. CAPA MULTI-TENANT: ORGANIZACIONES (TENANTS) Y GRANJAS (SEDES)
-- ============================================================================

CREATE TABLE avisena.tenants (
    tenant_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre_comercial    VARCHAR(150) NOT NULL,
    razon_social        VARCHAR(200),
    nit_rut             VARCHAR(30) UNIQUE,
    slug                VARCHAR(80) NOT NULL UNIQUE,
    plan_suscripcion    VARCHAR(30) NOT NULL DEFAULT 'PROFESIONAL'
                        CHECK (plan_suscripcion IN ('BASICO', 'PROFESIONAL', 'EMPRESARIAL', 'INSTITUCIONAL_SENA')),
    estado              VARCHAR(20) NOT NULL DEFAULT 'ACTIVO'
                        CHECK (estado IN ('ACTIVO', 'SUSPENDIDO', 'PRUEBA', 'CANCELADO')),
    max_galpones        INT NOT NULL DEFAULT 20 CHECK (max_galpones > 0),
    max_usuarios        INT NOT NULL DEFAULT 50 CHECK (max_usuarios > 0),
    configuracion_json  JSONB NOT NULL DEFAULT '{"moneda": "COP", "unidades_por_panal": 30, "gramos_ave_dia_default": 115}'::jsonb,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE avisena.granjas (
    granja_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    codigo_granja       VARCHAR(30) NOT NULL,
    nombre              VARCHAR(120) NOT NULL,
    departamento        VARCHAR(80),
    municipio           VARCHAR(80),
    direccion_vereda    VARCHAR(200),
    temperatura_prom_c  NUMERIC(4,1),
    altitud_msnm        INT,
    registro_ica        VARCHAR(60),
    estado              VARCHAR(20) NOT NULL DEFAULT 'ACTIVA'
                        CHECK (estado IN ('ACTIVA', 'INACTIVA', 'CUARENTENA')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (tenant_id, codigo_granja),
    UNIQUE (tenant_id, granja_id)
);

-- ============================================================================
-- 2. SEGURIDAD, ROLES, USUARIOS Y PREFERENCIAS (Módulos: /users, /profile, /configuracion)
-- ============================================================================

CREATE TABLE avisena.roles (
    rol_id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id           UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE CASCADE,
    codigo_rol          VARCHAR(40) NOT NULL, -- Ej: 'ADMIN', 'APRENDIZ', 'INVESTIGADOR', 'OPERARIO', 'VETERINARIO'
    nombre              VARCHAR(80) NOT NULL, -- Ej: 'Instructor Líder', 'Aprendiz de Contrato'
    descripcion         VARCHAR(250),
    permisos_json       JSONB NOT NULL DEFAULT '{}'::jsonb,
    es_sistema          BOOLEAN NOT NULL DEFAULT FALSE,
    estado              BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (tenant_id, codigo_rol),
    UNIQUE (tenant_id, nombre),
    UNIQUE (tenant_id, rol_id)
);

CREATE TABLE avisena.usuarios (
    usuario_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    rol_id              BIGINT NOT NULL,
    nombre_completo     VARCHAR(150) NOT NULL,
    correo_electronico  CITEXT NOT NULL,
    numero_celular      VARCHAR(25),
    tipo_documento      VARCHAR(10) NOT NULL DEFAULT 'CC'
                        CHECK (tipo_documento IN ('CC', 'TI', 'CE', 'PPT', 'NIT', 'PAS')),
    numero_documento    VARCHAR(30) NOT NULL,
    residencia          VARCHAR(200),
    fecha_ingreso       DATE NOT NULL DEFAULT CURRENT_DATE,
    password_hash       VARCHAR(255) NOT NULL,
    avatar_url          TEXT,
    biografia_cargo     VARCHAR(300),
    estado              VARCHAR(15) NOT NULL DEFAULT 'ACTIVO'
                        CHECK (estado IN ('ACTIVO', 'INACTIVO', 'BLOQUEADO')),
    ultimo_acceso       TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at          TIMESTAMPTZ,
    UNIQUE (tenant_id, correo_electronico),
    UNIQUE (tenant_id, tipo_documento, numero_documento),
    UNIQUE (tenant_id, usuario_id),
    CONSTRAINT fk_usuarios_rol_tenant
        FOREIGN KEY (tenant_id, rol_id)
        REFERENCES avisena.roles(tenant_id, rol_id)
        ON UPDATE CASCADE ON DELETE RESTRICT
);

-- Mapea exactamente con /configuracion (avisena_settings en el frontend)
CREATE TABLE avisena.configuraciones_usuario (
    usuario_id              UUID PRIMARY KEY REFERENCES avisena.usuarios(usuario_id) ON DELETE CASCADE,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE CASCADE,
    theme                   VARCHAR(15) NOT NULL DEFAULT 'light' CHECK (theme IN ('light', 'dark', 'auto')),
    language                VARCHAR(10) NOT NULL DEFAULT 'es' CHECK (language IN ('es', 'en')),
    remember_session        BOOLEAN NOT NULL DEFAULT TRUE,
    desktop_notifications   BOOLEAN NOT NULL DEFAULT FALSE,
    auto_save               BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- 3. CATÁLOGO ZOOTÉCNICO: LÍNEAS GENÉTICAS Y CURVAS DE REFERENCIA
-- (Soporta cálculo automático de semanas de vida según peso en formlotenuevo.jsx)
-- ============================================================================

CREATE TABLE avisena.lineas_geneticas (
    linea_id                INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre                  VARCHAR(80) NOT NULL UNIQUE, -- 'Hy-line brown', 'Lohmann brown', 'Dekalb', 'ISA brown', 'Babcock'
    proposito               VARCHAR(30) NOT NULL DEFAULT 'POSTURA' CHECK (proposito IN ('POSTURA', 'ENGORDE', 'DOBLE_PROPOSITO')),
    edad_inicio_postura_sem INT NOT NULL DEFAULT 17,
    consumo_adulto_g_dia    NUMERIC(6,2) NOT NULL DEFAULT 115.00,
    activo                  BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE avisena.curvas_referencia_genetica (
    curva_id                INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    linea_id                INT NOT NULL REFERENCES avisena.lineas_geneticas(linea_id) ON DELETE CASCADE,
    semana_vida             INT NOT NULL CHECK (semana_vida BETWEEN 1 AND 120),
    peso_esperado_g         NUMERIC(7,2) NOT NULL CHECK (peso_esperado_g > 0),
    consumo_esperado_g_dia  NUMERIC(6,2),
    pct_postura_esperado    NUMERIC(5,2) CHECK (pct_postura_esperado BETWEEN 0 AND 100),
    UNIQUE (linea_id, semana_vida)
);

-- ============================================================================
-- 4. INFRAESTRUCTURA (GALPONES) Y CICLO BIOLÓGICO (LOTES DE AVES)
-- (Resuelve el problema de mezclar el edificio físico con la parvada de gallinas)
-- ============================================================================

-- 4.1. Galpón físico (dura décadas)
CREATE TABLE avisena.galpones (
    galpon_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    granja_id               UUID NOT NULL,
    numero_galpon           VARCHAR(30) NOT NULL, -- Soporta '1', '2', '01', 'A-1', 'Galpón 1'
    nombre_etiqueta         VARCHAR(80) NOT NULL, -- Ej: 'Galpón 1'
    capacidad_maxima_aves   INT NOT NULL DEFAULT 5000 CHECK (capacidad_maxima_aves > 0),
    sistema_produccion      VARCHAR(40) NOT NULL DEFAULT 'PISO'
                            CHECK (sistema_produccion IN ('PISO', 'JAULA_CONVENCIONAL', 'AVIARIO_LIBRE', 'PASTOREO')),
    estado_galpon           VARCHAR(25) NOT NULL DEFAULT 'OPERATIVO'
                            CHECK (estado_galpon IN ('OPERATIVO', 'VACIO_SANITARIO', 'MANTENIMIENTO', 'CUARENTENA', 'INACTIVO')),
    observaciones           VARCHAR(500),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (tenant_id, granja_id, numero_galpon),
    UNIQUE (tenant_id, galpon_id),
    CONSTRAINT fk_galpones_granja_tenant
        FOREIGN KEY (tenant_id, granja_id)
        REFERENCES avisena.granjas(tenant_id, granja_id)
        ON UPDATE CASCADE ON DELETE RESTRICT
);

-- 4.2. Lote / Parvada de aves (ciclo productivo de ~80-100 semanas dentro de un galpón)
-- Mapea 1:1 con AdminGalponesView.jsx y formlotenuevo.jsx
CREATE TABLE avisena.lotes_aves (
    lote_id                     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id                   UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    galpon_id                   BIGINT NOT NULL,
    codigo_lote                 VARCHAR(50) NOT NULL, -- Ej: 'LOTE-2026-01'
    fecha_ingreso               DATE NOT NULL,
    hora_ingreso                TIME NOT NULL DEFAULT '08:00:00',
    linea_genetica_id           INT REFERENCES avisena.lineas_geneticas(linea_id) ON DELETE SET NULL,
    linea_genetica_nombre       VARCHAR(80) NOT NULL, -- Guarda 'Hy-line brown' u 'Otra' ingresada manualmente
    peso_promedio_ingreso_g     NUMERIC(8,2) NOT NULL CHECK (peso_promedio_ingreso_g > 0),
    semana_vida_ingreso         INT NOT NULL CHECK (semana_vida_ingreso BETWEEN 1 AND 120),
    -- Fecha de nacimiento estimada para calcular dinámicamente la edad en cualquier fecha futura
    fecha_nacimiento_estimada   DATE GENERATED ALWAYS AS (fecha_ingreso - (semana_vida_ingreso * 7)) STORED,
    aves_iniciales              INT NOT NULL CHECK (aves_iniciales > 0),
    aves_actuales               INT NOT NULL CHECK (aves_actuales >= 0),
    meta_gramos_ave_dia         NUMERIC(6,2) NOT NULL DEFAULT 115.00 CHECK (meta_gramos_ave_dia > 0), -- Usado en FCR (prodfunfinal)
    responsable_usuario_id      UUID,
    responsable_nombre          VARCHAR(150) NOT NULL,
    -- En producción real se guarda la URL en S3/R2/Supabase Storage y metadatos aquí (no base64 pesado en texto)
    certificado_archivo_url     TEXT,
    certificado_metadata        JSONB DEFAULT NULL, -- {"name": "cert.pdf", "type": "application/pdf", "size_bytes": 124000}
    observaciones               VARCHAR(500),
    estado_lote                 VARCHAR(20) NOT NULL DEFAULT 'ACTIVO'
                                CHECK (estado_lote IN ('ACTIVO', 'EN_CUARENTENA', 'CERRADO', 'DESCARTADO')),
    fecha_cierre                DATE,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at                  TIMESTAMPTZ,
    UNIQUE (tenant_id, codigo_lote),
    UNIQUE (tenant_id, lote_id),
    CONSTRAINT chk_aves_actuales_no_supera_iniciales CHECK (aves_actuales <= aves_iniciales),
    CONSTRAINT fk_lotes_galpon_tenant
        FOREIGN KEY (tenant_id, galpon_id)
        REFERENCES avisena.galpones(tenant_id, galpon_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_lotes_responsable_tenant
        FOREIGN KEY (tenant_id, responsable_usuario_id)
        REFERENCES avisena.usuarios(tenant_id, usuario_id)
        ON UPDATE CASCADE ON DELETE SET NULL
);

-- Función auxiliar para calcular la edad en semanas y semana de producción (igual que en prodfunfinal/page.jsx)
CREATE OR REPLACE FUNCTION avisena.fn_calcular_edad_lote(
    p_fecha_ingreso DATE,
    p_semana_ingreso INT,
    p_fecha_evento DATE
)
RETURNS TABLE(semana_vida INT, semana_produccion INT)
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT
        GREATEST(1, FLOOR(p_semana_ingreso + ((p_fecha_evento - p_fecha_ingreso)::NUMERIC / 7.0))::INT) AS semana_vida,
        CASE
            WHEN (p_semana_ingreso + ((p_fecha_evento - p_fecha_ingreso)::NUMERIC / 7.0)) >= 17
            THEN FLOOR(p_semana_ingreso + ((p_fecha_evento - p_fecha_ingreso)::NUMERIC / 7.0))::INT - 16
            ELSE NULL
        END AS semana_produccion;
$$;

-- ============================================================================
-- 5. PRODUCCIÓN DIARIA DE HUEVOS Y ALIMENTACIÓN / FCR
-- (Mapea 1:1 con /prodfunfinal/page.jsx)
-- ============================================================================

CREATE TABLE avisena.produccion_huevos (
    produccion_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    galpon_id               BIGINT NOT NULL,
    lote_id                 BIGINT NOT NULL,
    usuario_id              UUID,
    trabajador_nombre       VARCHAR(150) NOT NULL,
    fecha_recoleccion       DATE NOT NULL,
    hora_recoleccion        TIME NOT NULL DEFAULT CURRENT_TIME,
    jornada                 VARCHAR(20) NOT NULL DEFAULT 'Mañana'
                            CHECK (jornada IN ('Mañana', 'Tarde', 'Noche', 'Única')),
    linea_genetica          VARCHAR(80),
    edad_semanas            INT NOT NULL CHECK (edad_semanas >= 1),
    semana_produccion       INT CHECK (semana_produccion IS NULL OR semana_produccion >= 1),
    -- Snapshot de aves vivas al momento de recolectar (permite calcular % postura exacto histórico)
    aves_presentes_dia      INT NOT NULL CHECK (aves_presentes_dia > 0),
    huevos_buenos           INT NOT NULL DEFAULT 0 CHECK (huevos_buenos >= 0),
    huevos_rotos            INT NOT NULL DEFAULT 0 CHECK (huevos_rotos >= 0),
    huevos_descarte         INT NOT NULL DEFAULT 0 CHECK (huevos_descarte >= 0),
    total_huevos            INT GENERATED ALWAYS AS (huevos_buenos + huevos_rotos + huevos_descarte) STORED,
    -- Reemplaza produccionesPendientes en localStorage
    estado_clasificacion    VARCHAR(20) NOT NULL DEFAULT 'PENDIENTE'
                            CHECK (estado_clasificacion IN ('PENDIENTE', 'CLASIFICADO', 'OMITIDO')),
    observaciones           VARCHAR(500),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (tenant_id, produccion_id),
    CONSTRAINT fk_produccion_galpon_tenant
        FOREIGN KEY (tenant_id, galpon_id)
        REFERENCES avisena.galpones(tenant_id, galpon_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_produccion_lote_tenant
        FOREIGN KEY (tenant_id, lote_id)
        REFERENCES avisena.lotes_aves(tenant_id, lote_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_produccion_usuario_tenant
        FOREIGN KEY (tenant_id, usuario_id)
        REFERENCES avisena.usuarios(tenant_id, usuario_id)
        ON UPDATE CASCADE ON DELETE SET NULL
);

CREATE TABLE avisena.alimentacion_aves (
    alimentacion_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    galpon_id               BIGINT NOT NULL,
    lote_id                 BIGINT NOT NULL,
    usuario_id              UUID,
    fecha_suministro        DATE NOT NULL DEFAULT CURRENT_DATE,
    tipo_alimento           VARCHAR(60) NOT NULL DEFAULT 'Postura Fase 1',
    cantidad_kg             NUMERIC(10,2) NOT NULL CHECK (cantidad_kg > 0),
    bultos_50kg             NUMERIC(10,2) GENERATED ALWAYS AS (ROUND(cantidad_kg / 50.0, 2)) STORED,
    aves_presentes_dia      INT NOT NULL CHECK (aves_presentes_dia > 0),
    gramos_meta_ave_dia     NUMERIC(6,2) NOT NULL DEFAULT 115.00,
    consumo_teorico_kg      NUMERIC(10,2) GENERATED ALWAYS AS (ROUND((aves_presentes_dia * gramos_meta_ave_dia) / 1000.0, 2)) STORED,
    observaciones           VARCHAR(300),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_alimentacion_galpon_tenant
        FOREIGN KEY (tenant_id, galpon_id)
        REFERENCES avisena.galpones(tenant_id, galpon_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_alimentacion_lote_tenant
        FOREIGN KEY (tenant_id, lote_id)
        REFERENCES avisena.lotes_aves(tenant_id, lote_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_alimentacion_usuario_tenant
        FOREIGN KEY (tenant_id, usuario_id)
        REFERENCES avisena.usuarios(tenant_id, usuario_id)
        ON UPDATE CASCADE ON DELETE SET NULL
);

-- ============================================================================
-- 6. CLASIFICACIÓN DE HUEVOS, CONTROL DE SOBRANTES E INVENTARIO DE PANALES
-- (Mapea 1:1 con /registro_clasificacion/page.jsx)
-- ============================================================================

-- 6.1. Cabecera del evento de clasificación
CREATE TABLE avisena.clasificacion_huevos (
    clasificacion_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id                   UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    codigo_registro             VARCHAR(30) NOT NULL, -- Ej: 'REC-001'
    fecha_clasificacion         DATE NOT NULL DEFAULT CURRENT_DATE,
    galpon_id                   BIGINT NOT NULL,
    lote_id                     BIGINT,
    -- Puede vincularse a una recolección específica (produccionSeleccionada) o ser independiente
    produccion_id               BIGINT,
    usuario_id                  UUID,
    responsable_nombre          VARCHAR(150) NOT NULL,
    total_unidades_clasificadas INT NOT NULL CHECK (total_unidades_clasificadas > 0),
    total_panales_generados     INT NOT NULL DEFAULT 0 CHECK (total_panales_generados >= 0),
    total_sobrantes_unidades    INT NOT NULL DEFAULT 0 CHECK (total_sobrantes_unidades >= 0),
    valor_estimado_cop          NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    transferido_a_finanzas      BOOLEAN NOT NULL DEFAULT FALSE,
    observaciones               VARCHAR(500),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (tenant_id, codigo_registro),
    UNIQUE (tenant_id, produccion_id),
    UNIQUE (tenant_id, clasificacion_id),
    CONSTRAINT fk_clasif_galpon_tenant
        FOREIGN KEY (tenant_id, galpon_id)
        REFERENCES avisena.galpones(tenant_id, galpon_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_clasif_lote_tenant
        FOREIGN KEY (tenant_id, lote_id)
        REFERENCES avisena.lotes_aves(tenant_id, lote_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_clasif_produccion_tenant
        FOREIGN KEY (tenant_id, produccion_id)
        REFERENCES avisena.produccion_huevos(tenant_id, produccion_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_clasif_usuario_tenant
        FOREIGN KEY (tenant_id, usuario_id)
        REFERENCES avisena.usuarios(tenant_id, usuario_id)
        ON UPDATE CASCADE ON DELETE SET NULL
);

-- 6.2. Detalle por calibre (C, B, A, AA, AAA, Jumbo) con matemática exacta de panales (30 uds) y sobrantes
CREATE TABLE avisena.clasificacion_huevos_detalle (
    detalle_id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id                   UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE CASCADE,
    clasificacion_id            BIGINT NOT NULL,
    calibre                     VARCHAR(10) NOT NULL
                                CHECK (calibre IN ('C', 'B', 'A', 'AA', 'AAA', 'Jumbo')),
    unidades_hoy                INT NOT NULL DEFAULT 0 CHECK (unidades_hoy >= 0),
    sobrante_anterior           INT NOT NULL DEFAULT 0 CHECK (sobrante_anterior BETWEEN 0 AND 29),
    unidades_acumuladas         INT GENERATED ALWAYS AS (
                                    CASE WHEN unidades_hoy > 0 THEN unidades_hoy + sobrante_anterior ELSE 0 END
                                ) STORED,
    panales_completos           INT GENERATED ALWAYS AS (
                                    CASE WHEN unidades_hoy > 0 THEN FLOOR((unidades_hoy + sobrante_anterior) / 30.0)::INT ELSE 0 END
                                ) STORED,
    sobrante_siguiente          INT GENERATED ALWAYS AS (
                                    CASE WHEN unidades_hoy > 0 THEN MOD(unidades_hoy + sobrante_anterior, 30) ELSE sobrante_anterior END
                                ) STORED,
    precio_panal_referencia     NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (precio_panal_referencia >= 0),
    subtotal_estimado           NUMERIC(14,2) GENERATED ALWAYS AS (
                                    (CASE WHEN unidades_hoy > 0 THEN FLOOR((unidades_hoy + sobrante_anterior) / 30.0)::INT ELSE 0 END)
                                    * precio_panal_referencia
                                ) STORED,
    UNIQUE (clasificacion_id, calibre),
    CONSTRAINT fk_clasif_detalle_cabecera
        FOREIGN KEY (tenant_id, clasificacion_id)
        REFERENCES avisena.clasificacion_huevos(tenant_id, clasificacion_id)
        ON UPDATE CASCADE ON DELETE CASCADE
);

-- 6.3. Stock e Inventario Vivo de Huevos por Galpón y Calibre
-- Permite saber al instante cuántos panales hay listos para vender y cuántos huevos sueltos quedaron de ayer
CREATE TABLE avisena.inventario_huevos_galpon (
    inventario_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id                   UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE CASCADE,
    galpon_id                   BIGINT NOT NULL,
    calibre                     VARCHAR(10) NOT NULL
                                CHECK (calibre IN ('C', 'B', 'A', 'AA', 'AAA', 'Jumbo')),
    panales_disponibles         INT NOT NULL DEFAULT 0 CHECK (panales_disponibles >= 0),
    unidades_sobrantes          INT NOT NULL DEFAULT 0 CHECK (unidades_sobrantes BETWEEN 0 AND 29),
    precio_panal_actual         NUMERIC(12,2) NOT NULL DEFAULT 12000.00 CHECK (precio_panal_actual >= 0),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (tenant_id, galpon_id, calibre),
    CONSTRAINT fk_inventario_galpon_tenant
        FOREIGN KEY (tenant_id, galpon_id)
        REFERENCES avisena.galpones(tenant_id, galpon_id)
        ON UPDATE CASCADE ON DELETE CASCADE
);

-- ============================================================================
-- 7. SANIDAD AVÍCOLA: MORTALIDAD, MORBILIDAD Y TRATAMIENTOS
-- (Mapea 1:1 con /mortalidad, /morbilidad y /tratamiento)
-- ============================================================================

-- 7.1. Mortalidad (FormMortalidad.jsx)
CREATE TABLE avisena.mortalidad_aves (
    mortalidad_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    galpon_id               BIGINT NOT NULL,
    lote_id                 BIGINT NOT NULL,
    usuario_id              UUID,
    fecha_mortalidad        DATE NOT NULL DEFAULT CURRENT_DATE,
    cantidad_aves           INT NOT NULL CHECK (cantidad_aves > 0),
    edad_semanas            INT NOT NULL CHECK (edad_semanas >= 1),
    causa_muerte            VARCHAR(200) NOT NULL,
    resultado_necropsia     TEXT NOT NULL,
    disposicion_final       TEXT NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_mortalidad_galpon_tenant
        FOREIGN KEY (tenant_id, galpon_id)
        REFERENCES avisena.galpones(tenant_id, galpon_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_mortalidad_lote_tenant
        FOREIGN KEY (tenant_id, lote_id)
        REFERENCES avisena.lotes_aves(tenant_id, lote_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_mortalidad_usuario_tenant
        FOREIGN KEY (tenant_id, usuario_id)
        REFERENCES avisena.usuarios(tenant_id, usuario_id)
        ON UPDATE CASCADE ON DELETE SET NULL
);

-- 7.2. Morbilidad (FormMorbilidad.jsx)
CREATE TABLE avisena.morbilidad_aves (
    morbilidad_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    galpon_id               BIGINT NOT NULL,
    lote_id                 BIGINT,
    usuario_id              UUID,
    responsable_nombre      VARCHAR(150) NOT NULL,
    fecha_reporte           DATE NOT NULL DEFAULT CURRENT_DATE,
    grado_afectacion        VARCHAR(20) NOT NULL DEFAULT 'Leve'
                            CHECK (grado_afectacion IN ('Leve', 'Moderado', 'Crítico', 'Critico')),
    aves_afectadas          INT NOT NULL CHECK (aves_afectadas > 0),
    accion_inmediata        VARCHAR(80) NOT NULL
                            CHECK (accion_inmediata IN (
                                'Aislamiento',
                                'Inicio de tratamiento',
                                'Cuarentena de Galpón',
                                'Revisión Veterinaria',
                                'Otra'
                            )),
    sintomas                TEXT NOT NULL,
    observaciones_tecnicas  TEXT,
    concepto_veterinario    TEXT,
    estado_caso             VARCHAR(25) NOT NULL DEFAULT 'ABIERTO'
                            CHECK (estado_caso IN ('ABIERTO', 'EN_TRATAMIENTO', 'RESUELTO')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (tenant_id, morbilidad_id),
    CONSTRAINT fk_morbilidad_galpon_tenant
        FOREIGN KEY (tenant_id, galpon_id)
        REFERENCES avisena.galpones(tenant_id, galpon_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_morbilidad_lote_tenant
        FOREIGN KEY (tenant_id, lote_id)
        REFERENCES avisena.lotes_aves(tenant_id, lote_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_morbilidad_usuario_tenant
        FOREIGN KEY (tenant_id, usuario_id)
        REFERENCES avisena.usuarios(tenant_id, usuario_id)
        ON UPDATE CASCADE ON DELETE SET NULL
);

-- 7.3. Tratamientos Veterinarios (FormTratamiento.jsx)
CREATE TABLE avisena.tratamientos_aves (
    tratamiento_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    galpon_id               BIGINT NOT NULL,
    lote_id                 BIGINT,
    morbilidad_id           BIGINT, -- Soporta el autofill desde Morbilidad (tratamientoAutofill)
    usuario_id              UUID,
    responsable_nombre      VARCHAR(150) NOT NULL,
    medico_veterinario      VARCHAR(150),
    fecha_inicio            DATE NOT NULL DEFAULT CURRENT_DATE,
    duracion_dias           INT NOT NULL DEFAULT 3 CHECK (duracion_dias BETWEEN 1 AND 90),
    fecha_fin_estimada      DATE GENERATED ALWAYS AS (fecha_inicio + duracion_dias) STORED,
    medicamento             VARCHAR(150) NOT NULL, -- Ej: 'Enrofloxacina'
    tipo_tratamiento        VARCHAR(50) NOT NULL DEFAULT 'Antimicrobiano'
                            CHECK (tipo_tratamiento IN (
                                'Antimicrobiano',
                                'Antiparasitario',
                                'Vitaminas',
                                'Antiinflamatorio',
                                'Vacuna',
                                'Otro'
                            )),
    dosis_suministro        VARCHAR(80) NOT NULL, -- Ej: '10 ml'
    via_administracion      VARCHAR(40) NOT NULL DEFAULT 'Agua'
                            CHECK (via_administracion IN ('Agua', 'Alimento', 'Inyección', 'Tópico', 'Ocular/Nasal')),
    dias_retiro_huevos      INT NOT NULL DEFAULT 0 CHECK (dias_retiro_huevos >= 0),
    observaciones           TEXT,
    estado_tratamiento      VARCHAR(20) NOT NULL DEFAULT 'ACTIVO'
                            CHECK (estado_tratamiento IN ('ACTIVO', 'FINALIZADO', 'SUSPENDIDO')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_tratamiento_galpon_tenant
        FOREIGN KEY (tenant_id, galpon_id)
        REFERENCES avisena.galpones(tenant_id, galpon_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_tratamiento_lote_tenant
        FOREIGN KEY (tenant_id, lote_id)
        REFERENCES avisena.lotes_aves(tenant_id, lote_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_tratamiento_morbilidad_tenant
        FOREIGN KEY (tenant_id, morbilidad_id)
        REFERENCES avisena.morbilidad_aves(tenant_id, morbilidad_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_tratamiento_usuario_tenant
        FOREIGN KEY (tenant_id, usuario_id)
        REFERENCES avisena.usuarios(tenant_id, usuario_id)
        ON UPDATE CASCADE ON DELETE SET NULL
);

-- ============================================================================
-- 8. FINANZAS AVÍCOLAS Y VENTAS MULTI-CLASIFICADAS
-- (Mapea 1:1 con /finanzas/page.jsx, incluyendo desgloseInventario y gasto 10% asociado)
-- ============================================================================

CREATE TABLE avisena.finanzas_transacciones (
    transaccion_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE RESTRICT,
    granja_id               UUID,
    -- galpon_id y lote_id son NULLABLE para permitir gastos generales de la granja (energía, administración)
    galpon_id               BIGINT,
    lote_id                 BIGINT,
    clasificacion_origen_id BIGINT, -- Si se importó desde /registro_clasificacion
    transaccion_padre_id    BIGINT, -- Si es el gasto automático del 10% asociado a una venta (asociarGastoInmediato)
    usuario_id              UUID,
    fecha_operacion         DATE NOT NULL DEFAULT CURRENT_DATE,
    tipo_operacion          VARCHAR(15) NOT NULL CHECK (tipo_operacion IN ('Ingreso', 'Gasto')),
    categoria               VARCHAR(50) NOT NULL
                            CHECK (categoria IN ('Venta de Huevos', 'Alimentos', 'Salud/Vet', 'Infraestructura', 'Nómina', 'Servicios', 'Otros')),
    concepto                VARCHAR(255) NOT NULL,
    detalle_operacion       TEXT,
    es_multi_clasificada    BOOLEAN NOT NULL DEFAULT FALSE,
    -- Para ventas simples de un solo calibre:
    calibre_huevo           VARCHAR(10) CHECK (calibre_huevo IS NULL OR calibre_huevo IN ('C', 'B', 'A', 'AA', 'AAA', 'Jumbo', 'Mixto')),
    panales_vendidos        INT CHECK (panales_vendidos IS NULL OR panales_vendidos >= 0),
    precio_por_panal        NUMERIC(12,2) CHECK (precio_por_panal IS NULL OR precio_por_panal >= 0),
    -- Para compras de insumos/gastos:
    cantidad_insumo         NUMERIC(12,2) CHECK (cantidad_insumo IS NULL OR cantidad_insumo >= 0),
    precio_unitario_insumo  NUMERIC(12,2) CHECK (precio_unitario_insumo IS NULL OR precio_unitario_insumo >= 0),
    monto_total             NUMERIC(14,2) NOT NULL CHECK (monto_total >= 0),
    estado_operacion        VARCHAR(20) NOT NULL DEFAULT 'Completado'
                            CHECK (estado_operacion IN ('Completado', 'Pendiente', 'Atrasado', 'Cancelado')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at              TIMESTAMPTZ,
    UNIQUE (tenant_id, transaccion_id),
    CONSTRAINT fk_finanzas_galpon_tenant
        FOREIGN KEY (tenant_id, galpon_id)
        REFERENCES avisena.galpones(tenant_id, galpon_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_finanzas_lote_tenant
        FOREIGN KEY (tenant_id, lote_id)
        REFERENCES avisena.lotes_aves(tenant_id, lote_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_finanzas_clasif_tenant
        FOREIGN KEY (tenant_id, clasificacion_origen_id)
        REFERENCES avisena.clasificacion_huevos(tenant_id, clasificacion_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_finanzas_padre_tenant
        FOREIGN KEY (tenant_id, transaccion_padre_id)
        REFERENCES avisena.finanzas_transacciones(tenant_id, transaccion_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_finanzas_usuario_tenant
        FOREIGN KEY (tenant_id, usuario_id)
        REFERENCES avisena.usuarios(tenant_id, usuario_id)
        ON UPDATE CASCADE ON DELETE SET NULL
);

-- Detalle normalizado de desgloseInventario cuando es una Venta Multi-Clasificada
CREATE TABLE avisena.finanzas_venta_huevos_detalle (
    venta_detalle_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE CASCADE,
    transaccion_id          BIGINT NOT NULL,
    calibre                 VARCHAR(10) NOT NULL CHECK (calibre IN ('C', 'B', 'A', 'AA', 'AAA', 'Jumbo')),
    unidades_equivalentes   INT NOT NULL DEFAULT 0 CHECK (unidades_equivalentes >= 0),
    panales_vendidos        INT NOT NULL CHECK (panales_vendidos > 0),
    precio_panal            NUMERIC(12,2) NOT NULL CHECK (precio_panal >= 0),
    subtotal                NUMERIC(14,2) GENERATED ALWAYS AS (panales_vendidos * precio_panal) STORED,
    UNIQUE (transaccion_id, calibre),
    CONSTRAINT fk_finanzas_detalle_tx
        FOREIGN KEY (tenant_id, transaccion_id)
        REFERENCES avisena.finanzas_transacciones(tenant_id, transaccion_id)
        ON UPDATE CASCADE ON DELETE CASCADE
);

-- ============================================================================
-- 9. NOTIFICACIONES EN TIEMPO REAL Y AUDITORÍA
-- (Mapea 1:1 con /notificaciones/page.jsx)
-- ============================================================================

CREATE TABLE avisena.notificaciones (
    notificacion_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE CASCADE,
    galpon_id               BIGINT,
    lote_id                 BIGINT,
    usuario_destino_id      UUID, -- NULL = visible para todos los usuarios del tenant
    severidad               VARCHAR(15) NOT NULL DEFAULT 'info'
                            CHECK (severidad IN ('critical', 'warning', 'success', 'info')),
    categoria               VARCHAR(30) NOT NULL DEFAULT 'Sistema'
                            CHECK (categoria IN ('Mortalidad', 'Producción', 'Salud', 'Inventario', 'Finanzas', 'Ambiente', 'Sistema')),
    titulo                  VARCHAR(150) NOT NULL,
    descripcion              VARCHAR(500) NOT NULL,
    leida                   BOOLEAN NOT NULL DEFAULT FALSE,
    fecha_lectura           TIMESTAMPTZ,
    metadata_json           JSONB DEFAULT '{}'::jsonb,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_notif_galpon_tenant
        FOREIGN KEY (tenant_id, galpon_id)
        REFERENCES avisena.galpones(tenant_id, galpon_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_notif_lote_tenant
        FOREIGN KEY (tenant_id, lote_id)
        REFERENCES avisena.lotes_aves(tenant_id, lote_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_notif_usuario_tenant
        FOREIGN KEY (tenant_id, usuario_destino_id)
        REFERENCES avisena.usuarios(tenant_id, usuario_id)
        ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE avisena.audit_logs (
    audit_id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id               UUID NOT NULL REFERENCES avisena.tenants(tenant_id) ON DELETE CASCADE,
    usuario_id              UUID,
    tabla_afectada          VARCHAR(60) NOT NULL,
    registro_id             VARCHAR(80) NOT NULL,
    accion                  VARCHAR(15) NOT NULL CHECK (accion IN ('INSERT', 'UPDATE', 'DELETE')),
    datos_anteriores        JSONB,
    datos_nuevos            JSONB,
    ip_origen               INET,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- 10. TRIGGERS DE LÓGICA DE NEGOCIO AVÍCOLA (INTEGRIDAD TRANSACCIONAL)
-- ============================================================================

-- 10.1. Al registrar, editar o eliminar mortalidad:
--       1) Actualiza automáticamente aves_actuales en lotes_aves.
--       2) Si la mortalidad del evento supera el 2% del lote, crea una notificación 'critical'.
CREATE OR REPLACE FUNCTION avisena.fn_sincronizar_mortalidad_lote()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_aves_iniciales INT;
    v_aves_actuales INT;
    v_pct_mortalidad NUMERIC(6,2);
    v_nombre_galpon VARCHAR(80);
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE avisena.lotes_aves
           SET aves_actuales = aves_actuales - NEW.cantidad_aves,
               updated_at = CURRENT_TIMESTAMP
         WHERE tenant_id = NEW.tenant_id
           AND lote_id = NEW.lote_id
        RETURNING aves_iniciales, aves_actuales INTO v_aves_iniciales, v_aves_actuales;

        IF v_aves_actuales < 0 THEN
            RAISE EXCEPTION 'La mortalidad registrada (%) supera las aves vivas actuales del lote.', NEW.cantidad_aves;
        END IF;

        -- Verificar alerta de mortalidad crítica (> 2% en un evento)
        IF v_aves_iniciales > 0 THEN
            v_pct_mortalidad := ROUND((NEW.cantidad_aves::NUMERIC / v_aves_iniciales::NUMERIC) * 100, 2);
            IF v_pct_mortalidad >= 2.0 THEN
                SELECT nombre_etiqueta INTO v_nombre_galpon
                  FROM avisena.galpones
                 WHERE tenant_id = NEW.tenant_id AND galpon_id = NEW.galpon_id;

                INSERT INTO avisena.notificaciones (
                    tenant_id, galpon_id, lote_id, severidad, categoria, titulo, descripcion
                ) VALUES (
                    NEW.tenant_id,
                    NEW.galpon_id,
                    NEW.lote_id,
                    'critical',
                    'Mortalidad',
                    FORMAT('Alta Mortalidad: %s', COALESCE(v_nombre_galpon, 'Galpón')),
                    FORMAT('Se registraron %s bajas (%s%% del lote). Causa: %s.', NEW.cantidad_aves, v_pct_mortalidad, NEW.causa_muerte)
                );
            END IF;
        END IF;
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.lote_id = NEW.lote_id THEN
            UPDATE avisena.lotes_aves
               SET aves_actuales = aves_actuales + OLD.cantidad_aves - NEW.cantidad_aves,
                   updated_at = CURRENT_TIMESTAMP
             WHERE tenant_id = NEW.tenant_id
               AND lote_id = NEW.lote_id;
        ELSE
            UPDATE avisena.lotes_aves
               SET aves_actuales = aves_actuales + OLD.cantidad_aves,
                   updated_at = CURRENT_TIMESTAMP
             WHERE tenant_id = OLD.tenant_id AND lote_id = OLD.lote_id;

            UPDATE avisena.lotes_aves
               SET aves_actuales = aves_actuales - NEW.cantidad_aves,
                   updated_at = CURRENT_TIMESTAMP
             WHERE tenant_id = NEW.tenant_id AND lote_id = NEW.lote_id;
        END IF;
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        UPDATE avisena.lotes_aves
           SET aves_actuales = aves_actuales + OLD.cantidad_aves,
               updated_at = CURRENT_TIMESTAMP
         WHERE tenant_id = OLD.tenant_id
           AND lote_id = OLD.lote_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_sincronizar_mortalidad_lote
AFTER INSERT OR UPDATE OR DELETE ON avisena.mortalidad_aves
FOR EACH ROW EXECUTE FUNCTION avisena.fn_sincronizar_mortalidad_lote();

-- 10.2. Al clasificar una recolección (clasificacion_huevos):
--       Marca automáticamente la recolección de origen como 'CLASIFICADO'.
CREATE OR REPLACE FUNCTION avisena.fn_marcar_produccion_clasificada()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.produccion_id IS NOT NULL THEN
        UPDATE avisena.produccion_huevos
           SET estado_clasificacion = 'CLASIFICADO',
               updated_at = CURRENT_TIMESTAMP
         WHERE tenant_id = NEW.tenant_id
           AND produccion_id = NEW.produccion_id;
    ELSIF TG_OP = 'DELETE' AND OLD.produccion_id IS NOT NULL THEN
        UPDATE avisena.produccion_huevos
           SET estado_clasificacion = 'PENDIENTE',
               updated_at = CURRENT_TIMESTAMP
         WHERE tenant_id = OLD.tenant_id
           AND produccion_id = OLD.produccion_id;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_marcar_produccion_clasificada
AFTER INSERT OR DELETE ON avisena.clasificacion_huevos
FOR EACH ROW EXECUTE FUNCTION avisena.fn_marcar_produccion_clasificada();

-- 10.3. Al insertar detalle de clasificación:
--       Actualiza el inventario vivo de panales y los sobrantes para el día siguiente.
CREATE OR REPLACE FUNCTION avisena.fn_actualizar_inventario_clasificacion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_galpon_id BIGINT;
BEGIN
    SELECT galpon_id INTO v_galpon_id
      FROM avisena.clasificacion_huevos
     WHERE tenant_id = NEW.tenant_id
       AND clasificacion_id = NEW.clasificacion_id;

    INSERT INTO avisena.inventario_huevos_galpon (
        tenant_id, galpon_id, calibre, panales_disponibles, unidades_sobrantes, precio_panal_actual, updated_at
    ) VALUES (
        NEW.tenant_id,
        v_galpon_id,
        NEW.calibre,
        NEW.panales_completos,
        NEW.sobrante_siguiente,
        NEW.precio_panal_referencia,
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (tenant_id, galpon_id, calibre)
    DO UPDATE SET
        panales_disponibles = avisena.inventario_huevos_galpon.panales_disponibles + EXCLUDED.panales_disponibles,
        unidades_sobrantes  = EXCLUDED.unidades_sobrantes,
        precio_panal_actual = CASE
                                WHEN EXCLUDED.precio_panal_actual > 0 THEN EXCLUDED.precio_panal_actual
                                ELSE avisena.inventario_huevos_galpon.precio_panal_actual
                              END,
        updated_at          = CURRENT_TIMESTAMP;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_actualizar_inventario_clasificacion
AFTER INSERT ON avisena.clasificacion_huevos_detalle
FOR EACH ROW EXECUTE FUNCTION avisena.fn_actualizar_inventario_clasificacion();

-- ============================================================================
-- 11. ÍNDICES DE ALTO RENDIMIENTO PARA MILLONES DE REGISTROS
-- ============================================================================

-- Índices compuestos Multi-Tenant (B-Tree) para consultas operativas y filtros de UI
CREATE INDEX idx_usuarios_tenant_rol ON avisena.usuarios (tenant_id, rol_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_galpones_tenant_granja ON avisena.galpones (tenant_id, granja_id, estado_galpon);
CREATE INDEX idx_lotes_tenant_galpon_estado ON avisena.lotes_aves (tenant_id, galpon_id, estado_lote) WHERE deleted_at IS NULL;

-- Producción diaria: búsqueda rápida por mes/día, pendientes de clasificar y por lote
CREATE INDEX idx_produccion_tenant_fecha ON avisena.produccion_huevos (tenant_id, fecha_recoleccion DESC, galpon_id);
CREATE INDEX idx_produccion_tenant_lote_fecha ON avisena.produccion_huevos (tenant_id, lote_id, fecha_recoleccion DESC);
CREATE INDEX idx_produccion_pendientes ON avisena.produccion_huevos (tenant_id, estado_clasificacion, fecha_recoleccion DESC)
    WHERE estado_clasificacion = 'PENDIENTE';

-- Alimentación: cálculo de FCR mensual
CREATE INDEX idx_alimentacion_tenant_lote_fecha ON avisena.alimentacion_aves (tenant_id, lote_id, fecha_suministro DESC);
CREATE INDEX idx_alimentacion_tenant_fecha ON avisena.alimentacion_aves (tenant_id, fecha_suministro DESC);

-- Clasificación de huevos
CREATE INDEX idx_clasificacion_tenant_fecha ON avisena.clasificacion_huevos (tenant_id, fecha_clasificacion DESC, galpon_id);

-- Sanidad (Mortalidad, Morbilidad, Tratamientos)
CREATE INDEX idx_mortalidad_tenant_fecha ON avisena.mortalidad_aves (tenant_id, fecha_mortalidad DESC, galpon_id);
CREATE INDEX idx_mortalidad_tenant_lote ON avisena.mortalidad_aves (tenant_id, lote_id, fecha_mortalidad DESC);
CREATE INDEX idx_morbilidad_tenant_fecha ON avisena.morbilidad_aves (tenant_id, fecha_reporte DESC, galpon_id);
CREATE INDEX idx_tratamientos_tenant_fecha ON avisena.tratamientos_aves (tenant_id, fecha_inicio DESC, galpon_id);

-- Finanzas: filtros por fecha, tipo (Ingreso/Gasto), categoría y galpón
CREATE INDEX idx_finanzas_tenant_fecha_tipo ON avisena.finanzas_transacciones (tenant_id, fecha_operacion DESC, tipo_operacion, categoria)
    WHERE deleted_at IS NULL;
CREATE INDEX idx_finanzas_tenant_galpon_fecha ON avisena.finanzas_transacciones (tenant_id, galpon_id, fecha_operacion DESC)
    WHERE deleted_at IS NULL;

-- Notificaciones: bandeja de no leídas y críticas (/notificaciones)
CREATE INDEX idx_notificaciones_bandeja ON avisena.notificaciones (tenant_id, leida, severidad, created_at DESC);

-- Índices BRIN (Block Range Index) ultraligeros para barridos históricos masivos de series temporales
CREATE INDEX idx_brin_produccion_fecha ON avisena.produccion_huevos USING BRIN (fecha_recoleccion);
CREATE INDEX idx_brin_alimentacion_fecha ON avisena.alimentacion_aves USING BRIN (fecha_suministro);
CREATE INDEX idx_brin_finanzas_fecha ON avisena.finanzas_transacciones USING BRIN (fecha_operacion);
CREATE INDEX idx_brin_audit_created ON avisena.audit_logs USING BRIN (created_at);

-- ============================================================================
-- 12. VISTAS ANALÍTICAS (FCR MENSUAL, POSTURA Y DASHBOARD)
-- ============================================================================

-- Vista de Conversión Alimenticia (FCR / CA) Mensual por Lote y Galpón
-- Implementa exactamente la fórmula de /prodfunfinal/page.jsx:
-- D = Total huevos mes / 12 (docenas) | K = Kg alimento mes | CA = K / D
CREATE OR REPLACE VIEW avisena.vw_fcr_mensual_lote AS
WITH prod_mensual AS (
    SELECT
        tenant_id,
        lote_id,
        galpon_id,
        DATE_TRUNC('month', fecha_recoleccion)::DATE AS mes,
        SUM(huevos_buenos) AS total_buenos,
        SUM(huevos_rotos) AS total_rotos,
        SUM(huevos_descarte) AS total_descarte,
        SUM(total_huevos) AS total_huevos,
        ROUND(SUM(total_huevos)::NUMERIC / 12.0, 2) AS docenas_producidas,
        ROUND(AVG((total_huevos::NUMERIC / NULLIF(aves_presentes_dia, 0)) * 100), 2) AS pct_postura_promedio
    FROM avisena.produccion_huevos
    GROUP BY tenant_id, lote_id, galpon_id, DATE_TRUNC('month', fecha_recoleccion)::DATE
),
alim_mensual AS (
    SELECT
        tenant_id,
        lote_id,
        DATE_TRUNC('month', fecha_suministro)::DATE AS mes,
        SUM(cantidad_kg) AS total_alimento_kg,
        SUM(consumo_teorico_kg) AS total_alimento_teorico_kg
    FROM avisena.alimentacion_aves
    GROUP BY tenant_id, lote_id, DATE_TRUNC('month', fecha_suministro)::DATE
)
SELECT
    COALESCE(p.tenant_id, a.tenant_id) AS tenant_id,
    COALESCE(p.lote_id, a.lote_id) AS lote_id,
    p.galpon_id,
    COALESCE(p.mes, a.mes) AS mes,
    COALESCE(p.total_buenos, 0) AS huevos_buenos_mes,
    COALESCE(p.total_rotos, 0) AS huevos_rotos_mes,
    COALESCE(p.total_descarte, 0) AS huevos_descarte_mes,
    COALESCE(p.total_huevos, 0) AS total_huevos_mes,
    COALESCE(p.docenas_producidas, 0) AS docenas_mes,
    COALESCE(p.pct_postura_promedio, 0) AS pct_postura_promedio,
    COALESCE(a.total_alimento_kg, 0) AS alimento_real_kg,
    COALESCE(a.total_alimento_teorico_kg, 0) AS alimento_teorico_kg,
    CASE
        WHEN COALESCE(p.docenas_producidas, 0) > 0 AND COALESCE(a.total_alimento_kg, 0) > 0
        THEN ROUND(a.total_alimento_kg / p.docenas_producidas, 2)
        ELSE 0
    END AS conversion_alimenticia_ca,
    CASE
        WHEN COALESCE(p.docenas_producidas, 0) = 0 OR COALESCE(a.total_alimento_kg, 0) = 0 THEN 'Sin datos'
        WHEN (a.total_alimento_kg / p.docenas_producidas) <= 1.30 THEN 'Óptimo'
        WHEN (a.total_alimento_kg / p.docenas_producidas) <= 1.60 THEN 'Excelente'
        WHEN (a.total_alimento_kg / p.docenas_producidas) <= 1.80 THEN 'Bueno'
        WHEN (a.total_alimento_kg / p.docenas_producidas) <= 2.00 THEN 'Revisar'
        ELSE 'Deficiente'
    END AS evaluacion_ca
FROM prod_mensual p
FULL OUTER JOIN alim_mensual a
    ON p.tenant_id = a.tenant_id
   AND p.lote_id = a.lote_id
   AND p.mes = a.mes;

-- ============================================================================
-- 13. SEGURIDAD MULTI-TENANT: ROW-LEVEL SECURITY (RLS)
-- ============================================================================
-- Blinda todas las tablas operativas para que cada sesión solo acceda a su tenant_id.

ALTER TABLE avisena.granjas ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.usuarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.configuraciones_usuario ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.galpones ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.lotes_aves ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.produccion_huevos ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.alimentacion_aves ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.clasificacion_huevos ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.clasificacion_huevos_detalle ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.inventario_huevos_galpon ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.mortalidad_aves ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.morbilidad_aves ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.tratamientos_aves ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.finanzas_transacciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.finanzas_venta_huevos_detalle ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.notificaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisena.audit_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_granjas ON avisena.granjas
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_roles ON avisena.roles
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_usuarios ON avisena.usuarios
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_config_usuario ON avisena.configuraciones_usuario
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_galpones ON avisena.galpones
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_lotes ON avisena.lotes_aves
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_produccion ON avisena.produccion_huevos
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_alimentacion ON avisena.alimentacion_aves
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_clasificacion ON avisena.clasificacion_huevos
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_clasif_detalle ON avisena.clasificacion_huevos_detalle
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_inventario ON avisena.inventario_huevos_galpon
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_mortalidad ON avisena.mortalidad_aves
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_morbilidad ON avisena.morbilidad_aves
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_tratamientos ON avisena.tratamientos_aves
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_finanzas ON avisena.finanzas_transacciones
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_finanzas_detalle ON avisena.finanzas_venta_huevos_detalle
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_notificaciones ON avisena.notificaciones
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

CREATE POLICY tenant_isolation_audit ON avisena.audit_logs
    USING (tenant_id = avisena.current_tenant_id())
    WITH CHECK (tenant_id = avisena.current_tenant_id());

-- ============================================================================
-- 14. DATOS SEMILLA ZOOTÉCNICOS (CURVAS DE REFERENCIA DE LÍNEAS GENÉTICAS)
-- Extraídos directamente de formlotenuevo.jsx (PESOS_REFERENCIA Semanas 1-18)
-- ============================================================================

INSERT INTO avisena.lineas_geneticas (nombre, proposito, edad_inicio_postura_sem, consumo_adulto_g_dia)
VALUES
    ('Hy-line brown', 'POSTURA', 17, 112.00),
    ('Lohmann brown', 'POSTURA', 17, 115.00),
    ('Dekalb',        'POSTURA', 17, 110.00),
    ('isa brown',     'POSTURA', 17, 114.00),
    ('Babcock',       'POSTURA', 17, 114.00)
ON CONFLICT (nombre) DO NOTHING;

-- Curva Hy-line brown (Semanas 1 a 17)
INSERT INTO avisena.curvas_referencia_genetica (linea_id, semana_vida, peso_esperado_g)
SELECT l.linea_id, u.semana, u.peso
FROM avisena.lineas_geneticas l
CROSS JOIN UNNEST(
    ARRAY[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17],
    ARRAY[70,125,190,265,360,460,560,670,780,890,990,1080,1160,1230,1300,1370,1440]
) AS u(semana, peso)
WHERE l.nombre = 'Hy-line brown'
ON CONFLICT (linea_id, semana_vida) DO NOTHING;

-- Curva Lohmann brown (Semanas 1 a 18)
INSERT INTO avisena.curvas_referencia_genetica (linea_id, semana_vida, peso_esperado_g)
SELECT l.linea_id, u.semana, u.peso
FROM avisena.lineas_geneticas l
CROSS JOIN UNNEST(
    ARRAY[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18],
    ARRAY[75,130,195,273,366,469,573,677,777,873,963,1047,1128,1205,1279,1351,1421,1493]
) AS u(semana, peso)
WHERE l.nombre = 'Lohmann brown'
ON CONFLICT (linea_id, semana_vida) DO NOTHING;

-- Curva Dekalb (Semanas 1 a 18)
INSERT INTO avisena.curvas_referencia_genetica (linea_id, semana_vida, peso_esperado_g)
SELECT l.linea_id, u.semana, u.peso
FROM avisena.lineas_geneticas l
CROSS JOIN UNNEST(
    ARRAY[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18],
    ARRAY[61,115,170,240,330,430,530,621,710,800,890,985,1080,1165,1250,1335,1410,1460]
) AS u(semana, peso)
WHERE l.nombre = 'Dekalb'
ON CONFLICT (linea_id, semana_vida) DO NOTHING;

-- Curva ISA brown y Babcock (Semanas 1 a 18)
INSERT INTO avisena.curvas_referencia_genetica (linea_id, semana_vida, peso_esperado_g)
SELECT l.linea_id, u.semana, u.peso
FROM avisena.lineas_geneticas l
CROSS JOIN UNNEST(
    ARRAY[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18],
    ARRAY[69,123,185,259,352,453,554,656,756,854,948,1037,1123,1200,1276,1352,1424,1477]
) AS u(semana, peso)
WHERE l.nombre IN ('isa brown', 'Babcock')
ON CONFLICT (linea_id, semana_vida) DO NOTHING;

COMMIT;
