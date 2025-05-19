import os
from app import create_app
from config import config

# Get the configuration type from an environment variable, default to 'default'
config_name = os.getenv('FLASK_CONFIG', 'default')

# Create the app with the selected configuration
app = create_app(config[config_name])

if __name__ == '__main__':
    # Ensure host is always 0.0.0.0 for container
    host = getattr(config[config_name], 'HOST', '0.0.0.0') or '0.0.0.0'
    port = getattr(config[config_name], 'PORT', 5000) or 5000
    debug = getattr(config[config_name], 'DEBUG', False)
    app.run(
        host=host,
        port=port,
        debug=debug
    )