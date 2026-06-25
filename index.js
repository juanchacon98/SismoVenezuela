import express from 'express';
import pg from 'pg';
import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';
import { GoogleGenAI } from '@google/genai';

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
app.use(express.json());

const port = process.env.PORT || 8080;

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
});

// Servir archivos estáticos del frontend (como support.js y assets)
app.use(express.static(path.join(__dirname, 'frontend')));

// Ruta raíz para servir el HTML principal del frontend
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'frontend', 'Reporte Desaparecidos Venezuela.dc.html'));
});

// Endpoint de Health Check requerido por Google Cloud Run
app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1;');
    res.status(200).json({ status: 'ok', database: 'connected' });
  } catch (error) {
    res.status(500).json({ status: 'error', database: error.message });
  }
});

// Endpoint 1: Enviar reporte de emergencia atómico y de-duplicado (Acceso Público)
app.post('/api/reports', async (req, res) => {
  try {
    const payload = req.body;

    // Llamada al procedimiento almacenado SECURITY DEFINER en Postgres
    const result = await pool.query(
      'SELECT submit_emergency_report($1::jsonb) AS data;',
      [JSON.stringify(payload)]
    );

    const reportResponse = result.rows[0].data;

    if (reportResponse.success) {
      return res.status(201).json(reportResponse);
    } else {
      return res.status(400).json(reportResponse);
    }
  } catch (error) {
    console.error('Error al procesar reporte de emergencia:', error.message);
    return res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

// Endpoint 2: Listar reportes con filtros y agregación de personas desaparecidas (Acceso Público)
app.get('/api/reports', async (req, res) => {
  const { type, urgency, is_resolved, limit = 50, offset = 0 } = req.query;
  
  let queryText = `
    SELECT r.*, 
           COALESCE(
             json_agg(mp.*) FILTER (WHERE mp.id IS NOT NULL), 
             '[]'::json
           ) AS missing_persons
    FROM public.reports r
    LEFT JOIN public.missing_persons mp ON r.id = mp.report_id
  `;
  
  const values = [];
  const conditions = [];

  if (type) {
    values.push(type);
    conditions.push(`r.type = $${values.length}`);
  }
  if (urgency) {
    values.push(urgency);
    conditions.push(`r.urgency = $${values.length}`);
  }
  if (is_resolved !== undefined) {
    values.push(is_resolved === 'true');
    conditions.push(`r.is_resolved = $${values.length}`);
  }

  if (conditions.length > 0) {
    queryText += ' WHERE ' + conditions.join(' AND ');
  }

  queryText += ' GROUP BY r.id';
  queryText += ` ORDER BY r.created_at DESC LIMIT ${parseInt(limit)} OFFSET ${parseInt(offset)};`;

  try {
    const result = await pool.query(queryText, values);
    res.json({
      success: true,
      count: result.rows.length,
      data: result.rows
    });
  } catch (error) {
    console.error('Error al listar reportes:', error.message);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Endpoint 3: Marcar reporte como resuelto (Acceso Protegido por RLS de sesión)
app.patch('/api/reports/:id/resolve', async (req, res) => {
  const { id } = req.params;
  const client = await pool.connect();

  try {
    await client.query('BEGIN;');
    await client.query("SET LOCAL app.role = 'authenticated';");

    const updateResult = await client.query(
      `UPDATE public.reports 
       SET is_resolved = true 
       WHERE id = $1 
       RETURNING id, type, urgency, is_resolved;`,
      [id]
    );

    if (updateResult.rows.length === 0) {
      throw new Error('Reporte no encontrado o no tiene permisos de modificación.');
    }

    await client.query('COMMIT;');

    return res.status(200).json({
      success: true,
      message: 'El reporte de emergencia ha sido marcado como resuelto.',
      data: updateResult.rows[0]
    });
  } catch (error) {
    await client.query('ROLLBACK;');
    console.error('Error al marcar reporte como resuelto:', error.message);
    return res.status(403).json({
      success: false,
      error: error.message
    });
  } finally {
    client.release();
  }
});

// Endpoint 4: Sincronizar alertas externas usando Google Gemini + Search Grounding
app.post('/api/sync-external', async (req, res) => {
  try {
    let ai;
    // Autenticación inteligente: Usa API Key local o Vertex AI en GCP (IAM default credentials)
    if (process.env.GEMINI_API_KEY) {
      ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
    } else {
      ai = new GoogleGenAI({
        vertex: true,
        project: process.env.GCP_PROJECT_ID || 'praxis-ia-498305',
        location: 'us-central1'
      });
    }

    console.log('Iniciando rastreo web con IA y Google Search Grounding...');

    const prompt = `
      Busca reportes recientes en Twitter, X y portales de noticias oficiales sobre emergencias médicas, 
      solicitudes de suministros, colapsos estructurales o personas desaparecidas causadas por el terremoto 
      de magnitud 7.2 en Caracas, Venezuela.
      Extrae exclusivamente información relevante que incluya referencias físicas de ubicación e incidentes reales.
      Devuelve los datos estrictamente mapeados en un arreglo conforme al esquema JSON solicitado.
    `;

    const response = await ai.models.generateContent({
      model: 'gemini-2.5-flash',
      contents: prompt,
      config: {
        tools: [{ googleSearch: {} }],
        responseMimeType: 'application/json',
        responseSchema: {
          type: 'ARRAY',
          items: {
            type: 'OBJECT',
            properties: {
              type: { 
                type: 'STRING', 
                enum: ['desaparecido', 'emergencia_medica', 'rescate_estructural', 'suministros'] 
              },
              urgency: { 
                type: 'STRING', 
                enum: ['critico', 'alto', 'moderado'] 
              },
              description: { type: 'STRING' },
              location_text: { type: 'STRING' },
              lat: { type: 'NUMBER' },
              lng: { type: 'NUMBER' },
              contact_info: { type: 'STRING' },
              missing_person: {
                type: 'OBJECT',
                properties: {
                  full_name: { type: 'STRING' },
                  physical_description: { type: 'STRING' },
                  last_seen_location: { type: 'STRING' }
                },
                required: ['full_name']
              }
            },
            required: ['type', 'urgency', 'description', 'location_text']
          }
        }
      }
    });

    const parsedReports = JSON.parse(response.text);
    console.log(`Gemini obtuvo ${parsedReports.length} reportes de la web. Ejecutando de-duplicación...`);

    const results = [];
    for (const r of parsedReports) {
      try {
        const dbResult = await pool.query(
          'SELECT submit_emergency_report($1::jsonb) AS data;',
          [JSON.stringify(r)]
        );
        results.push({
          report: { type: r.type, location_text: r.location_text },
          status: dbResult.rows[0].data
        });
      } catch (insertErr) {
        console.error('Error al insertar reporte sincronizado:', insertErr.message);
        results.push({
          report: { type: r.type, location_text: r.location_text },
          error: insertErr.message
        });
      }
    }

    res.json({
      success: true,
      synchronized_records: parsedReports.length,
      details: results
    });

  } catch (error) {
    console.error('Error crítico en sync-external:', error.message);
    res.status(500).json({ success: false, error: error.message });
  }
});

app.listen(port, () => {
  console.log(`Servidor de emergencia escuchando en el puerto ${port}`);
});
