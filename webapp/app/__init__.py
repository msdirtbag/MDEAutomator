from flask import Flask
import os
import sys
import logging

def create_app(config_class=None):
    # Set up import paths for MCP server components
    current_dir = os.path.dirname(os.path.abspath(__file__))
    if current_dir not in sys.path:
        sys.path.insert(0, current_dir)
    
    mcp_dir = os.path.join(current_dir, 'mdeautomator_mcp')
    if mcp_dir not in sys.path:
        sys.path.insert(0, mcp_dir)
    
    # Perform environment diagnostics early
    _perform_app_startup_diagnostics()
    
    app = Flask(__name__)
    
    # Apply configuration if provided
    if config_class:
        config_class.init_app(app)
    
    # Load environment variables into Flask config
    app.config['FUNCTION_APP_BASE_URL'] = os.environ.get('FUNCTION_APP_BASE_URL')
    app.config['FUNCTION_KEY'] = os.environ.get('FUNCTION_KEY')
    
    # Load Azure AI variables into Flask config
    app.config['AZURE_AI_ENDPOINT'] = os.environ.get('AZURE_AI_ENDPOINT')
    app.config['AZURE_AI_KEY'] = os.environ.get('AZURE_AI_KEY')
    app.config['AZURE_AI_DEPLOYMENT'] = os.environ.get('AZURE_AI_DEPLOYMENT', 'gpt-4')
    
    # Import and register blueprints
    from .routes import main_bp
    app.register_blueprint(main_bp)
    
    # Import and register WebUI proxy blueprint
    try:
        # Import from the parent webapp directory
        webapp_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        if webapp_dir not in sys.path:
            sys.path.insert(0, webapp_dir)
        
        from webui_routes import webui_bp
        app.register_blueprint(webui_bp)
        app.logger.info("✅ WebUI proxy blueprint registered successfully")
    except ImportError as e:
        app.logger.warning(f"⚠️ WebUI proxy blueprint not available: {e}")
    
    return app

def _perform_app_startup_diagnostics():
    """Perform early application startup diagnostics."""
    # Set up basic logging for startup diagnostics
    logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
    logger = logging.getLogger(__name__)
    
    logger.info("🚀 === FLASK APP STARTUP DIAGNOSTICS ===")
    
    # Check if running in Azure App Service
    website_site_name = os.getenv('WEBSITE_SITE_NAME')
    if website_site_name:
        logger.info(f"🔍 Running in Azure App Service: {website_site_name}")
        logger.info(f"🔍 Resource Group: {os.getenv('WEBSITE_RESOURCE_GROUP', 'Unknown')}")
        
        # Check for critical variables - using current variable names
        critical_vars = ['FUNCTION_APP_BASE_URL', 'FUNCTION_KEY', 'AZURE_AI_ENDPOINT', 'AZURE_AI_KEY']
        missing_vars = []
        
        for var in critical_vars:
            value = os.getenv(var)
            if value:
                logger.info(f"✅ {var}: Present ({len(value)} chars)")
            else:
                logger.warning(f"❌ {var}: Missing")
                missing_vars.append(var)
        
        if missing_vars:
            logger.error(f"❌ Critical variables missing: {', '.join(missing_vars)}")
            logger.error("❌ Check Azure App Service Configuration > Application Settings")
        else:
            logger.info("✅ All critical environment variables present")
    else:
        logger.info("🔍 Running in local development environment")
    
    logger.info("🚀 === FLASK APP STARTUP DIAGNOSTICS COMPLETE ===")