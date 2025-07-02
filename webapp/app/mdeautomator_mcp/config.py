"""
Configuration management for MDEAutomator MCP Server.

This module handles all configuration settings including Azure Function App URLs,
authentication settings, logging configuration, and security parameters.
"""

import os
from typing import Dict, List, Optional

from pydantic import BaseModel, Field, validator


class MCPConfig(BaseModel):
    """Configuration for the MDEAutomator MCP Server."""
    
    # Azure Function App Configuration
    function_app_base_url: str = Field(
        ..., 
        description="Base URL for MDEAutomator Function Apps (e.g., https://mdeautomator-dev.azurewebsites.net)"
    )
    
    # Azure AI Configuration
    azure_ai_endpoint: Optional[str] = Field(
        None,
        description="Azure AI Foundry/OpenAI endpoint URL"
    )
    azure_ai_key: Optional[str] = Field(
        None,
        description="Azure AI Foundry/OpenAI API key"
    )
    azure_ai_deployment: str = Field(
        "gpt-4",
        description="Azure AI model deployment name"
    )
    
    # Authentication Configuration
    azure_client_id: Optional[str] = Field(
        None, 
        description="Azure Client ID for Managed Identity authentication"
    )
    function_key: Optional[str] = Field(
        None, 
        description="Function key for Function App authentication"
    )
    key_vault_url: Optional[str] = Field(
        None, 
        description="Azure Key Vault URL for secrets retrieval"
    )
    
    # Request Configuration
    request_timeout: int = Field(
        300, 
        description="HTTP request timeout in seconds",
        ge=30,
        le=3600
    )
    max_retries: int = Field(
        3, 
        description="Maximum number of retry attempts",
        ge=1,
        le=10
    )
    retry_delay: float = Field(
        1.0, 
        description="Initial retry delay in seconds",
        ge=0.1,
        le=60.0
    )
    
    # Rate Limiting Configuration
    rate_limit_requests: int = Field(
        100, 
        description="Maximum requests per minute",
        ge=1,
        le=1000
    )
    rate_limit_burst: int = Field(
        20, 
        description="Maximum burst requests",
        ge=1,
        le=100
    )
    
    # Logging Configuration
    log_level: str = Field(
        "INFO", 
        description="Logging level (DEBUG, INFO, WARNING, ERROR, CRITICAL)"
    )
    enable_audit_logging: bool = Field(
        True, 
        description="Enable comprehensive audit logging"
    )
    
    # Security Configuration
    enable_request_validation: bool = Field(
        True, 
        description="Enable request parameter validation"
    )
    max_device_ids_per_request: int = Field(
        1000, 
        description="Maximum device IDs per request",
        ge=1,
        le=10000
    )
    max_indicators_per_request: int = Field(
        1000, 
        description="Maximum threat indicators per request",
        ge=1,
        le=10000
    )
    
    # Function App Endpoints
    function_endpoints: Dict[str, str] = Field(
        default_factory=lambda: {
            "MDEAutomator": "/api/MDEAutomator",
            "MDEDispatcher": "/api/MDEDispatcher", 
            "MDEOrchestrator": "/api/MDEOrchestrator",
            "MDEHunter": "/api/MDEHunter",
            "MDEHuntManager": "/api/MDEHuntManager",
            "MDEHuntScheduler": "/api/MDEHuntScheduler",
            "MDEIncidentManager": "/api/MDEIncidentManager",
            "MDETIManager": "/api/MDETIManager",
            "MDECDManager": "/api/MDECDManager",
            "MDEAutoChat": "/api/MDEAutoChat",
            "MDEAutoDB": "/api/MDEAutoDB",
            "MDEAutoHunt": "/api/MDEAutoHunt",
            "MDEProfiles": "/api/MDEProfiles"
        },
        description="Function App endpoint mappings"
    )
    
    @validator("log_level")
    def validate_log_level(cls, v):
        """Validate log level."""
        valid_levels = ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]
        if v.upper() not in valid_levels:
            raise ValueError(f"Log level must be one of: {valid_levels}")
        return v.upper()
    
    @validator("function_app_base_url")
    def validate_function_app_url(cls, v):
        """Validate Function App base URL."""
        if not v.startswith(("http://", "https://")):
            raise ValueError("Function App base URL must start with http:// or https://")
        if v.endswith("/"):
            v = v.rstrip("/")
        return v
    
    @classmethod
    def from_environment(cls) -> "MCPConfig":
        """Create configuration from environment variables."""
        return cls(
            # Azure Function App Configuration
            function_app_base_url=os.getenv(
                "FUNCTION_APP_BASE_URL", 
                "https://mdeautomator.azurewebsites.net"
            ),
            
            # Azure AI Configuration
            azure_ai_endpoint=os.getenv("AZURE_AI_ENDPOINT"),
            azure_ai_key=os.getenv("AZURE_AI_KEY"),
            azure_ai_deployment=os.getenv("AZURE_AI_DEPLOYMENT", "gpt-4"),
            
            # Authentication Configuration
            azure_client_id=os.getenv("AZURE_CLIENT_ID"),
            function_key=os.getenv("FUNCTION_KEY"),
            key_vault_url=os.getenv("KEY_VAULT_URL"),
            
            # Request Configuration
            request_timeout=int(os.getenv("REQUEST_TIMEOUT", "300")),
            max_retries=int(os.getenv("MAX_RETRIES", "3")),
            retry_delay=float(os.getenv("RETRY_DELAY", "1.0")),
            
            # Rate Limiting Configuration
            rate_limit_requests=int(os.getenv("RATE_LIMIT_REQUESTS", "100")),
            rate_limit_burst=int(os.getenv("RATE_LIMIT_BURST", "20")),
            
            # Logging Configuration
            log_level=os.getenv("LOG_LEVEL", "INFO"),
            enable_audit_logging=os.getenv("ENABLE_AUDIT_LOGGING", "true").lower() == "true",
            
            # Security Configuration
            enable_request_validation=os.getenv("ENABLE_REQUEST_VALIDATION", "true").lower() == "true",
            max_device_ids_per_request=int(os.getenv("MAX_DEVICE_IDS_PER_REQUEST", "1000")),
            max_indicators_per_request=int(os.getenv("MAX_INDICATORS_PER_REQUEST", "1000")),
        )

    @classmethod
    def from_flask_config(cls, flask_config: dict) -> "MCPConfig":
        """Create configuration from Flask app configuration dictionary."""
        return cls(
            # Azure Function App Configuration
            function_app_base_url=(
                flask_config.get("FUNCTION_APP_BASE_URL") or
                os.getenv("FUNCTION_APP_BASE_URL", "https://mdeautomator.azurewebsites.net")
            ),
            
            # Azure AI Configuration
            azure_ai_endpoint=(
                flask_config.get("AZURE_AI_ENDPOINT") or
                os.getenv("AZURE_AI_ENDPOINT")
            ),
            azure_ai_key=(
                flask_config.get("AZURE_AI_KEY") or
                os.getenv("AZURE_AI_KEY")
            ),
            azure_ai_deployment=(
                flask_config.get("AZURE_AI_DEPLOYMENT") or
                os.getenv("AZURE_AI_DEPLOYMENT", "gpt-4")
            ),
            
            # Authentication Configuration
            azure_client_id=(
                flask_config.get("AZURE_CLIENT_ID") or
                os.getenv("AZURE_CLIENT_ID")
            ),
            function_key=(
                flask_config.get("FUNCTION_KEY") or
                os.getenv("FUNCTION_KEY")
            ),
            key_vault_url=(
                flask_config.get("KEY_VAULT_URL") or
                os.getenv("KEY_VAULT_URL")
            ),
            
            # Request Configuration
            request_timeout=int(os.getenv("REQUEST_TIMEOUT", "300")),
            max_retries=int(os.getenv("MAX_RETRIES", "3")),
            retry_delay=float(os.getenv("RETRY_DELAY", "1.0")),
            
            # Rate Limiting Configuration
            rate_limit_requests=int(os.getenv("RATE_LIMIT_REQUESTS", "100")),
            rate_limit_burst=int(os.getenv("RATE_LIMIT_BURST", "20")),
            
            # Logging Configuration
            log_level=os.getenv("LOG_LEVEL", "INFO"),
            enable_audit_logging=os.getenv("ENABLE_AUDIT_LOGGING", "true").lower() == "true",
            
            # Security Configuration
            enable_request_validation=os.getenv("ENABLE_REQUEST_VALIDATION", "true").lower() == "true",
            max_device_ids_per_request=int(os.getenv("MAX_DEVICE_IDS_PER_REQUEST", "1000")),
            max_indicators_per_request=int(os.getenv("MAX_INDICATORS_PER_REQUEST", "1000")),
        )
    
    def get_function_url(self, function_name: str) -> str:
        """Get the full URL for a specific function."""
        endpoint = self.function_endpoints.get(function_name)
        if not endpoint:
            raise ValueError(f"Unknown function: {function_name}")
        return f"{self.function_app_base_url}{endpoint}"
    
    class Config:
        """Pydantic configuration."""
        env_prefix = "MCP_"
        case_sensitive = False
