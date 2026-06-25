-- ========================================================
-- Capa Backend Google Cloud SQL (PostgreSQL) - Catástrofe Caracas
-- Base de Datos: emergencia_ccs
-- ========================================================

-- 1. EXTENSIONES REQUERIDAS
CREATE EXTENSION IF NOT EXISTS pg_trgm; -- Habilita similitud trigram para búsquedas difusas y de-duplicación

-- 2. ENUMS DE APLICACIÓN (Encapsulados en un bloque DO para garantizar idempotencia)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'incident_type') THEN
        CREATE TYPE incident_type AS ENUM ('desaparecido', 'emergencia_medica', 'rescate_estructural', 'suministros');
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
    is_resolved BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now())
);

-- Migración de esquema en caliente para bases de datos ya existentes (idempotente)
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS title TEXT;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS source_url TEXT;

-- 4. TABLA SECUNDARIA: missing_persons (Creación Idempotente)
CREATE TABLE IF NOT EXISTS public.missing_persons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID NOT NULL REFERENCES public.reports(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    physical_description TEXT,
    last_seen_location TEXT
);

-- 5. ÍNDICES DE OPTIMIZACIÓN (Creación Idempotente)
CREATE INDEX IF NOT EXISTS idx_reports_active_feed ON public.reports (is_resolved, urgency, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reports_type ON public.reports (type);
CREATE INDEX IF NOT EXISTS idx_missing_persons_report_id ON public.missing_persons (report_id);
CREATE INDEX IF NOT EXISTS idx_missing_persons_name_trgm ON public.missing_persons USING gin (full_name gin_trgm_ops);

-- ========================================================
-- SEGURIDAD A NIVEL DE FILAS (RLS) EN CLOUD SQL
-- ========================================================
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.missing_persons ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.reports FORCE ROW LEVEL SECURITY;
ALTER TABLE public.missing_persons FORCE ROW LEVEL SECURITY;

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

-- ========================================================
-- ROL Y PERMISOS DE CONEXIÓN PARA EL BACKEND (Cloud Run)
-- ========================================================
GRANT USAGE ON SCHEMA public TO app_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO app_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO app_user;

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
BEGIN
    -- 1. Extracción de variables
    v_type := payload->>'type';
    v_urgency := payload->>'urgency';
    v_title := payload->>'title';
    v_source_url := payload->>'source_url';
    v_description := payload->>'description';
    v_location_text := payload->>'location_text';
    v_lat := (payload->>'lat')::DOUBLE PRECISION;
    v_lng := (payload->>'lng')::DOUBLE PRECISION;
    v_contact_info := payload->>'contact_info';
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
    IF NOT (v_type IN ('desaparecido', 'emergencia_medica', 'rescate_estructural', 'suministros')) THEN
        RAISE EXCEPTION 'Tipo de incidente inválido: %', v_type;
    END IF;
    IF NOT (v_urgency IN ('critico', 'alto', 'moderado')) THEN
        RAISE EXCEPTION 'Nivel de urgencia inválido: %', v_urgency;
    END IF;

    -- 3. Búsqueda de Duplicados en Reportes Activos (No Resueltos)
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

    -- 4. Bifurcación: Fusión o Inserción
    IF v_duplicate_id IS NOT NULL THEN
        -- SE DETECTÓ UN DUPLICADO: Fusionamos la información
        v_report_id := v_duplicate_id;
        v_status := 'merged';

        UPDATE public.reports
        SET description = description || E'\n\n[Actualización ' || to_char(timezone('utc', now()), 'YYYY-MM-DD HH24:MI:SS') || ' UTC]: ' || v_description,
            contact_info = CASE 
                WHEN v_contact_info IS NOT NULL AND v_contact_info != '' THEN 
                    COALESCE(contact_info, '') || ' | ' || v_contact_info
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
            contact_info
        ) VALUES (
            v_type::incident_type,
            v_urgency::urgency_level,
            v_title,
            v_source_url,
            v_description,
            v_location_text,
            v_lat,
            v_lng,
            v_contact_info
        ) RETURNING id INTO v_report_id;
    END IF;

    -- 5. Procesamiento de Persona Desaparecida
    IF v_type = 'desaparecido' OR v_missing_person IS NOT NULL THEN
        IF v_missing_person IS NULL THEN
            RAISE EXCEPTION 'Se requiere el nodo "missing_person" para incidentes de tipo desaparecido.';
        END IF;

        v_mp_name := v_missing_person->>'full_name';
        v_mp_description := v_missing_person->>'physical_description';
        v_mp_last_seen := v_missing_person->>'last_seen_location';

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
