import express from 'express';
import pg from 'pg';
import dotenv from 'dotenv';

dotenv.config();

const app = express();
app.use(express.json());

const port = process.env.PORT || 8080;

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
});

// Endpoint de Health Check requerido por Google Cloud Run para validar despliegues
app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1;');
    res.status(200).json({ status: 'ok', database: 'connected' });
  } catch (error) {
    res.status(500).json({ status: 'error', database: error.message });
  }
});

// Endpoint 1: Enviar reporte de emergencia atómico (Acceso Público)
// Procesa toda la transacción en una sola llamada RPC para mitigar pérdidas de señal
app.post('/api/reports', async (req, res) => {
  try {
    const payload = req.body;

    // Llamada directa al procedimiento almacenado SECURITY DEFINER en Postgres
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

// Endpoint 2: Marcar reporte como resuelto (Acceso Protegido por RLS)
// Simula autenticación del backend y configura la sesión de base de datos antes de realizar el UPDATE
app.patch('/api/reports/:id/resolve', async (req, res) => {
  const { id } = req.params;
  const client = await pool.connect();

  try {
    // Iniciamos transacción para asociar la variable de sesión al hilo de conexión local
    await client.query('BEGIN;');

    // Establecemos app.role en la sesión local. Esto activará las políticas RLS del UPDATE
    await client.query("SET LOCAL app.role = 'authenticated';");

    // Ejecutar el update
    const updateResult = await client.query(
      `UPDATE public.reports 
       SET is_resolved = true 
       WHERE id = $1 
       RETURNING id, type, urgency, is_resolved;`,
      [id]
    );

    // Si la fila no existe o RLS bloquea la operación (ej. si app.role no hubiese sido establecido)
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

app.listen(port, () => {
  console.log(`Servidor de emergencia escuchando en el puerto ${port}`);
});
