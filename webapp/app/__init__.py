from flask import Flask
import os

def create_app(config_class=None):
    app = Flask(__name__)
    
    # Apply configuration if provided
    if config_class:
        config_class.init_app(app)
    
    # Load FUNCURL and FUNCKEY from environment variables
    app.config['FUNCURL'] = os.environ.get('FUNCURL')
    app.config['FUNCKEY'] = os.environ.get('FUNCKEY')
    
    # Import and register blueprints
    from .routes import main_bp
    app.register_blueprint(main_bp)
    
    return app