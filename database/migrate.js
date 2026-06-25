import pg from 'pg';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const runMigrations = async () => {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    console.error('ERROR: La variable de entorno DATABASE_URL no está definida.');
    process.exit(1);
  }

  console.log('Iniciando migración de base de datos en Google Cloud SQL...');
  const pool = new pg.Pool({ connectionString });

  try {
    // Lee schema.sql del mismo directorio (/database)
    const sqlPath = path.join(__dirname, 'schema.sql');
    const sql = fs.readFileSync(sqlPath, 'utf8');

    // Ejecuta el script SQL completo
    await pool.query(sql);
    console.log('Migración y carga de esquema completada exitosamente (Idempotente).');
    process.exit(0);
  } catch (error) {
    console.error('Error crítico durante la migración de base de datos:', error.message);
    process.exit(1);
  } finally {
    await pool.end();
  }
};

runMigrations();
