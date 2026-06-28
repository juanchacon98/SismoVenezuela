-- ========================================================
-- Capa Backend Google Cloud SQL (PostgreSQL) - Catástrofe Caracas
-- Base de Datos: emergencia_ccs
-- ========================================================

-- 1. EXTENSIONES REQUERIDAS
CREATE EXTENSION IF NOT EXISTS pg_trgm; -- Habilita similitud trigram para búsquedas difusas y de-duplicación
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- Habilita gen_random_uuid() en instalaciones que aún dependen de pgcrypto

-- 2. ENUMS DE APLICACIÓN (Encapsulados en un bloque DO para garantizar idempotencia)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'incident_type') THEN
        CREATE TYPE incident_type AS ENUM ('desaparecido', 'emergencia_medica', 'rescate_estructural', 'suministros', 'sin_comunicacion');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'urgency_level') THEN
        CREATE TYPE urgency_level AS ENUM ('critico', 'alto', 'moderado');
    END IF;
END$$;

-- 3. TABLA PRINCIPAL: reports (Creación Idempotente)
CREATE TABLE IF NOT EXISTS public.reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type incident_type NOT NULL,
    urgency urgency_level NOT NULL,
    title TEXT,                  -- Título descriptivo sintético (NUEVO)
    source_url TEXT,             -- Enlace/URL original del reporte (NUEVO)
    description TEXT NOT NULL,
    location_text TEXT NOT NULL, -- GPS inestable; la descripción física de la ubicación es obligatoria
    lat DOUBLE PRECISION,        -- Coordenada opcional
    lng DOUBLE PRECISION,        -- Coordenada opcional
    contact_info TEXT,           -- Permite reportes anónimos si se omite
    state TEXT,                  -- Estado federal de Venezuela (NUEVO)
    is_resolved BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now())
);

-- Migración de esquema en caliente para bases de datos ya existentes (idempotente)
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS title TEXT;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS source_url TEXT;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS state TEXT;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now());

-- 4. TABLA SECUNDARIA: missing_persons (Creación Idempotente)
CREATE TABLE IF NOT EXISTS public.missing_persons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID NOT NULL REFERENCES public.reports(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    physical_description TEXT,
    last_seen_location TEXT,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now())
);

ALTER TABLE public.missing_persons ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now());

-- 5. TABLA DE CENTROS DE ACOPIO (Creación Idempotente)
CREATE TABLE IF NOT EXISTS public.collection_centers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    location_text TEXT NOT NULL,
    lat DOUBLE PRECISION NOT NULL CHECK (lat BETWEEN -90 AND 90),
    lng DOUBLE PRECISION NOT NULL CHECK (lng BETWEEN -180 AND 180),
    supplies TEXT,
    schedule TEXT,
    contact_info TEXT,
    capacity_status TEXT NOT NULL DEFAULT 'operativo'
        CHECK (capacity_status IN ('operativo', 'alta_demanda', 'sin_capacidad')),
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now())
);

-- Migración de esquema en caliente para bases de datos ya existentes (idempotente)
ALTER TABLE public.collection_centers ADD COLUMN IF NOT EXISTS supplies TEXT;
ALTER TABLE public.collection_centers ADD COLUMN IF NOT EXISTS schedule TEXT;
ALTER TABLE public.collection_centers ADD COLUMN IF NOT EXISTS contact_info TEXT;
ALTER TABLE public.collection_centers ADD COLUMN IF NOT EXISTS capacity_status TEXT NOT NULL DEFAULT 'operativo';
ALTER TABLE public.collection_centers ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT true;

-- 5b. TABLA DE TELEMETRÍA DE CONECTIVIDAD (Creación Idempotente)
CREATE TABLE IF NOT EXISTS public.connectivity_telemetry (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    state TEXT NOT NULL,
    latency_ms INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now())
);

-- 6. ÍNDICES DE OPTIMIZACIÓN (Creación Idempotente)
CREATE INDEX IF NOT EXISTS idx_connectivity_telemetry_state_time ON public.connectivity_telemetry (state, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reports_active_feed ON public.reports (is_resolved, urgency, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reports_type ON public.reports (type);
CREATE INDEX IF NOT EXISTS idx_reports_pfif_export ON public.reports (type, updated_at ASC, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_missing_persons_report_id ON public.missing_persons (report_id);
CREATE INDEX IF NOT EXISTS idx_missing_persons_name_trgm ON public.missing_persons USING gin (full_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_collection_centers_active ON public.collection_centers (is_active, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_collection_centers_location ON public.collection_centers (lat, lng);

-- ========================================================
-- SEGURIDAD A NIVEL DE FILAS (RLS) EN CLOUD SQL
-- ========================================================
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.missing_persons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.collection_centers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connectivity_telemetry ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.reports FORCE ROW LEVEL SECURITY;
ALTER TABLE public.missing_persons FORCE ROW LEVEL SECURITY;
ALTER TABLE public.collection_centers FORCE ROW LEVEL SECURITY;
ALTER TABLE public.connectivity_telemetry FORCE ROW LEVEL SECURITY;

-- -- POLÍTICAS PARA: reports -- --
DROP POLICY IF EXISTS "Permitir select público en reports" ON public.reports;
CREATE POLICY "Permitir select público en reports" ON public.reports FOR SELECT USING (true);

DROP POLICY IF EXISTS "Permitir insert público en reports" ON public.reports;
CREATE POLICY "Permitir insert público en reports" ON public.reports FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "Permitir update a rescatistas autenticados" ON public.reports;
CREATE POLICY "Permitir update a rescatistas autenticados" ON public.reports FOR UPDATE 
USING (current_setting('app.role', true) = 'authenticated')
WITH CHECK (current_setting('app.role', true) = 'authenticated');

DROP POLICY IF EXISTS "Permitir delete a rescatistas autenticados" ON public.reports;
CREATE POLICY "Permitir delete a rescatistas autenticados" ON public.reports FOR DELETE 
USING (current_setting('app.role', true) = 'authenticated');

-- -- POLÍTICAS PARA: missing_persons -- --
DROP POLICY IF EXISTS "Permitir select público en missing_persons" ON public.missing_persons;
CREATE POLICY "Permitir select público en missing_persons" ON public.missing_persons FOR SELECT USING (true);

DROP POLICY IF EXISTS "Permitir insert público en missing_persons" ON public.missing_persons;
CREATE POLICY "Permitir insert público en missing_persons" ON public.missing_persons FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "Permitir update en missing_persons a rescatistas" ON public.missing_persons;
CREATE POLICY "Permitir update en missing_persons a rescatistas" ON public.missing_persons FOR UPDATE 
USING (current_setting('app.role', true) = 'authenticated')
WITH CHECK (current_setting('app.role', true) = 'authenticated');

DROP POLICY IF EXISTS "Permitir delete en missing_persons a rescatistas" ON public.missing_persons;
CREATE POLICY "Permitir delete en missing_persons a rescatistas" ON public.missing_persons FOR DELETE 
USING (current_setting('app.role', true) = 'authenticated');

-- -- POLÍTICAS PARA: collection_centers -- --
DROP POLICY IF EXISTS "Permitir select público en collection_centers" ON public.collection_centers;
CREATE POLICY "Permitir select público en collection_centers" ON public.collection_centers FOR SELECT USING (true);

DROP POLICY IF EXISTS "Permitir insert público en collection_centers" ON public.collection_centers;
CREATE POLICY "Permitir insert público en collection_centers" ON public.collection_centers FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "Permitir update en collection_centers a rescatistas" ON public.collection_centers;
CREATE POLICY "Permitir update en collection_centers a rescatistas" ON public.collection_centers FOR UPDATE
USING (current_setting('app.role', true) = 'authenticated')
WITH CHECK (current_setting('app.role', true) = 'authenticated');

DROP POLICY IF EXISTS "Permitir delete en collection_centers a rescatistas" ON public.collection_centers;
CREATE POLICY "Permitir delete en collection_centers a rescatistas" ON public.collection_centers FOR DELETE
USING (current_setting('app.role', true) = 'authenticated');

-- -- POLÍTICAS PARA: connectivity_telemetry -- --
DROP POLICY IF EXISTS "Permitir select público en connectivity_telemetry" ON public.connectivity_telemetry;
CREATE POLICY "Permitir select público en connectivity_telemetry" ON public.connectivity_telemetry FOR SELECT USING (true);

DROP POLICY IF EXISTS "Permitir insert público en connectivity_telemetry" ON public.connectivity_telemetry;
CREATE POLICY "Permitir insert público en connectivity_telemetry" ON public.connectivity_telemetry FOR INSERT WITH CHECK (true);

-- ========================================================
-- ROL Y PERMISOS DE CONEXIÓN PARA EL BACKEND (Cloud Run)
-- ========================================================
GRANT USAGE ON SCHEMA public TO app_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO app_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO app_user;

CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = timezone('utc'::text, now());
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS reports_touch_updated_at ON public.reports;
CREATE TRIGGER reports_touch_updated_at
BEFORE UPDATE ON public.reports
FOR EACH ROW
EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS missing_persons_touch_updated_at ON public.missing_persons;
CREATE TRIGGER missing_persons_touch_updated_at
BEFORE UPDATE ON public.missing_persons
FOR EACH ROW
EXECUTE FUNCTION public.touch_updated_at();

-- ========================================================
-- RPC ATÓMICO: PROCESAMIENTO CON DE-DUPLICACIÓN INTELIGENTE
-- ========================================================

CREATE OR REPLACE FUNCTION public.submit_emergency_report(payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER 
SET search_path = public
AS $$
DECLARE
    v_report_id UUID;
    v_duplicate_id UUID;
    v_type TEXT;
    v_urgency TEXT;
    v_title TEXT;
    v_source_url TEXT;
    v_description TEXT;
    v_location_text TEXT;
    v_lat DOUBLE PRECISION;
    v_lng DOUBLE PRECISION;
    v_contact_info TEXT;
    v_missing_person JSONB;
    v_mp_name TEXT;
    v_mp_description TEXT;
    v_mp_last_seen TEXT;
    v_mp_existing_id UUID;
    v_status TEXT;
    v_state TEXT;
BEGIN
    -- 1. Extracción de variables
    v_type := payload->>'type';
    v_urgency := payload->>'urgency';
    v_title := payload->>'title';
    v_source_url := payload->>'source_url';
    v_description := payload->>'description';
    v_location_text := payload->>'location_text';
    v_lat := NULLIF(payload->>'lat', '')::DOUBLE PRECISION;
    v_lng := NULLIF(payload->>'lng', '')::DOUBLE PRECISION;
    v_contact_info := payload->>'contact_info';
    v_state := payload->>'state';
    v_missing_person := payload->'missing_person';

    -- 2. Validaciones básicas obligatorias
    IF v_type IS NULL OR v_type = '' THEN
        RAISE EXCEPTION 'El campo "type" es requerido.';
    END IF;
    IF v_urgency IS NULL OR v_urgency = '' THEN
        RAISE EXCEPTION 'El campo "urgency" es requerido.';
    END IF;
    IF v_description IS NULL OR v_description = '' THEN
        RAISE EXCEPTION 'El campo "description" es requerido.';
    END IF;
    IF v_location_text IS NULL OR v_location_text = '' THEN
        RAISE EXCEPTION 'El campo "location_text" es requerido.';
    END IF;

    -- Validaciones de enums
    IF NOT (v_type IN ('desaparecido', 'emergencia_medica', 'rescate_estructural', 'suministros', 'sin_comunicacion')) THEN
        RAISE EXCEPTION 'Tipo de incidente inválido: %', v_type;
    END IF;
    IF NOT (v_urgency IN ('critico', 'alto', 'moderado')) THEN
        RAISE EXCEPTION 'Nivel de urgencia inválido: %', v_urgency;
    END IF;

    IF v_missing_person IS NOT NULL THEN
        v_mp_name := v_missing_person->>'full_name';
        v_mp_description := v_missing_person->>'physical_description';
        v_mp_last_seen := v_missing_person->>'last_seen_location';
    END IF;

    -- 3. Búsqueda de duplicados activos con reglas específicas para desaparecidos
    IF v_type = 'desaparecido' THEN
        IF v_missing_person IS NULL THEN
            RAISE EXCEPTION 'Se requiere el nodo "missing_person" para incidentes de tipo desaparecido.';
        END IF;

        IF v_mp_name IS NULL OR v_mp_name = '' THEN
            RAISE EXCEPTION 'El campo "missing_person.full_name" es obligatorio.';
        END IF;

        SELECT r.id INTO v_duplicate_id
        FROM public.reports r
        JOIN public.missing_persons mp ON mp.report_id = r.id
        WHERE r.type = 'desaparecido'::incident_type
          AND r.is_resolved = false
          AND (
            similarity(mp.full_name, v_mp_name) > 0.72
            OR (
              similarity(mp.full_name, v_mp_name) > 0.58
              AND similarity(COALESCE(mp.last_seen_location, r.location_text), COALESCE(NULLIF(v_mp_last_seen, ''), v_location_text)) > 0.42
            )
            OR (
              v_source_url IS NOT NULL
              AND v_source_url != ''
              AND length(v_source_url) > 45
              AND COALESCE(r.source_url, '') LIKE '%' || v_source_url || '%'
              AND similarity(mp.full_name, v_mp_name) > 0.5
            )
          )
        ORDER BY GREATEST(
            similarity(mp.full_name, v_mp_name),
            similarity(COALESCE(mp.last_seen_location, r.location_text), COALESCE(NULLIF(v_mp_last_seen, ''), v_location_text))
        ) DESC,
        r.created_at DESC
        LIMIT 1;
    ELSE
        SELECT id INTO v_duplicate_id
        FROM public.reports
        WHERE type = v_type::incident_type
          AND is_resolved = false
          AND (
            -- Criterio A: Distancia GPS menor a 500 metros (0.5 km) usando la fórmula Haversine
            (v_lat IS NOT NULL AND v_lng IS NOT NULL AND lat IS NOT NULL AND lng IS NOT NULL AND
             (6371 * acos(
               LEAST(1.0, GREATEST(-1.0,
                 cos(radians(v_lat)) * cos(radians(lat)) * cos(radians(lng) - radians(v_lng)) +
                 sin(radians(v_lat)) * sin(radians(lat))
               ))
             )) < 0.5)
            OR
            -- Criterio B: Similitud del texto de descripción > 40%
            (similarity(description, v_description) > 0.4)
            OR
            -- Criterio C: Similitud de la referencia de ubicación > 40%
            (similarity(location_text, v_location_text) > 0.4)
          )
        ORDER BY created_at DESC
        LIMIT 1;
    END IF;

    -- 4. Bifurcación: Fusión o Inserción
    IF v_duplicate_id IS NOT NULL THEN
        -- SE DETECTÓ UN DUPLICADO: Fusionamos la información
        v_report_id := v_duplicate_id;
        v_status := 'merged';

        UPDATE public.reports
        SET description = CASE
                WHEN position(v_description in description) > 0 THEN description
                ELSE description || E'\n\n[Actualización ' || to_char(timezone('utc', now()), 'YYYY-MM-DD HH24:MI:SS') || ' UTC]: ' || v_description
            END,
            contact_info = CASE 
                WHEN v_contact_info IS NOT NULL AND v_contact_info != '' AND COALESCE(contact_info, '') NOT LIKE '%' || v_contact_info || '%' THEN
                    CASE WHEN contact_info IS NOT NULL AND contact_info != '' THEN contact_info || ' | ' || v_contact_info ELSE v_contact_info END
                ELSE contact_info 
            END,
            -- Fusionamos URLs de origen si son diferentes
            source_url = CASE 
                WHEN v_source_url IS NOT NULL AND v_source_url != '' AND COALESCE(source_url, '') NOT LIKE '%' || v_source_url || '%' THEN 
                    CASE WHEN source_url IS NOT NULL AND source_url != '' THEN source_url || ' | ' || v_source_url ELSE v_source_url END
                ELSE source_url
            END
        WHERE id = v_duplicate_id;

    ELSE
        -- NO HAY DUPLICADOS: Insertar nuevo reporte
        v_status := 'created';
        INSERT INTO public.reports (
            type,
            urgency,
            title,
            source_url,
            description,
            location_text,
            lat,
            lng,
            contact_info,
            state
        ) VALUES (
            v_type::incident_type,
            v_urgency::urgency_level,
            v_title,
            v_source_url,
            v_description,
            v_location_text,
            v_lat,
            v_lng,
            v_contact_info,
            v_state
        ) RETURNING id INTO v_report_id;
    END IF;

    -- 5. Procesamiento de Persona Desaparecida
    IF v_type = 'desaparecido' OR v_missing_person IS NOT NULL THEN
        IF v_missing_person IS NULL THEN
            RAISE EXCEPTION 'Se requiere el nodo "missing_person" para incidentes de tipo desaparecido.';
        END IF;

        IF v_mp_name IS NULL OR v_mp_name = '' THEN
            RAISE EXCEPTION 'El campo "missing_person.full_name" es obligatorio.';
        END IF;

        -- Si fue fusionado (merged), verificamos que la persona no esté registrada previamente
        IF v_status = 'merged' THEN
            SELECT id INTO v_mp_existing_id
            FROM public.missing_persons
            WHERE report_id = v_report_id
              AND similarity(full_name, v_mp_name) > 0.6;
        END IF;

        -- Insertamos sólo si no existía previamente la persona bajo este reporte
        IF v_mp_existing_id IS NULL THEN
            INSERT INTO public.missing_persons (
                report_id,
                full_name,
                physical_description,
                last_seen_location
            ) VALUES (
                v_report_id,
                v_mp_name,
                v_mp_description,
                v_mp_last_seen
            );
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'report_id', v_report_id,
        'status', v_status
    );
END;
$$;
