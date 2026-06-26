import sys
import subprocess
import json
import os

# Auto-instalación inteligente de dependencias para asegurar portabilidad
def install_and_import(package, pip_name=None):
    if pip_name is None:
        pip_name = package
    try:
        __import__(package)
    except ImportError:
        print(f"Instalando dependencia faltante: {pip_name}...", file=sys.stderr)
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", pip_name])
        except Exception as e:
            print(f"Error al instalar {pip_name}: {str(e)}", file=sys.stderr)
            sys.exit(1)

# Asegurar scrapegraphai y nest-asyncio
install_and_import("scrapegraphai")
install_and_import("nest_asyncio", "nest-asyncio")
install_and_import("langchain_google_genai", "langchain-google-genai")
install_and_import("langchain_google_vertexai", "langchain-google-vertexai")

# --- PARCHE DE COMPATIBILIDAD PARA LANGCHAIN / CHATOLLAMA ---
try:
    from langchain_ollama import ChatOllama
    try:
        import langchain_community.chat_models
    except ImportError:
        import types
        langchain_community.chat_models = types.ModuleType("langchain_community.chat_models")
        sys.modules["langchain_community.chat_models"] = langchain_community.chat_models
    langchain_community.chat_models.ChatOllama = ChatOllama
except Exception as e:
    print(f"Advertencia al aplicar parche de compatibilidad ChatOllama: {str(e)}", file=sys.stderr)
# -------------------------------------------------------------

import nest_asyncio
from scrapegraphai.graphs import SmartScraperGraph

# Resolver event loop anidado en entornos asíncronos (como el runner de Node/Python)
nest_asyncio.apply()

def main():
    api_key = os.environ.get("GEMINI_API_KEY")
    
    # Configuración de LLM para ScrapeGraphAI
    # Por defecto intentará usar Google GenAI con la API Key proporcionada
    graph_config = {
        "llm": {
            "api_key": api_key,
            "model": "google_genai/gemini-2.5-flash",
        },
        "verbose": False
    }

    # Si no hay API Key de Gemini en el ambiente, intentar usar la configuración de Vertex AI (ADC) de GCP
    if not api_key:
        graph_config["llm"] = {
            "model": "google_vertexai/gemini-2.5-flash",
        }

    # Prompt descriptivo para extraer la lista estructurada de personas desaparecidas
    prompt = (
        "Extrae una lista estructurada de todas las personas desaparecidas (missing persons) "
        "reportadas en la página. Para cada persona, obtén los siguientes campos en formato JSON: "
        "'full_name' (nombre completo), 'last_seen_location' (último lugar visto), "
        "'description' (descripción física, ropa o detalles) y 'contact_info' (número de contacto o fuente)."
    )

    scraper = SmartScraperGraph(
        prompt=prompt,
        source="https://desaparecidosterremotovenezuela.com/",
        config=graph_config
    )

    try:
        raw_result = scraper.run()
        
        # Formatear la salida estándar como JSON válido
        if isinstance(raw_result, str):
            try:
                raw_result = json.loads(raw_result)
            except json.JSONDecodeError:
                pass
                
        output = {"success": True, "results": raw_result}
        print(json.dumps(output, ensure_ascii=False))
    except Exception as e:
        err_output = {"success": False, "error": str(e)}
        print(json.dumps(err_output, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
