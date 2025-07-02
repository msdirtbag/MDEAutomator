"""
HTTP client for Azure Function Apps communication.

This module provides a secure, authenticated HTTP client for communicating with
MDEAutomator Function Apps, including retry logic, rate limiting, and comprehensive
error handling.
"""

import asyncio
from typing import Any, Dict, Optional

import httpx
import structlog
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from asyncio_throttle import Throttler
from tenacity import (
    AsyncRetrying,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

try:
    from .config import MCPConfig
except ImportError:
    from config import MCPConfig

logger = structlog.get_logger(__name__)


class FunctionAppClient:
    """
    HTTP client for Azure Function Apps communication.
    
    Provides secure, authenticated access to MDEAutomator Function Apps with:
    - Azure Managed Identity authentication
    - Function key authentication fallback
    - Automatic retry logic with exponential backoff
    - Rate limiting and throttling
    - Comprehensive error handling and logging
    - Request/response validation
    """

    def __init__(self, config: MCPConfig):
        """Initialize the Function App client."""
        self.config = config
        self.credential = None
        self.secret_client = None
        self.http_client = None
        self.throttler = None
        self._function_key = None

    async def initialize(self) -> None:
        """Initialize the client with authentication and HTTP client."""
        try:
            # Initialize Azure credentials
            if self.config.azure_client_id:
                logger.info("Initializing with Azure Managed Identity", 
                          client_id=self.config.azure_client_id)
                self.credential = DefaultAzureCredential(
                    managed_identity_client_id=self.config.azure_client_id
                )
            else:
                logger.info("Initializing with default Azure credentials")
                self.credential = DefaultAzureCredential()

            # Initialize Key Vault client if configured
            if self.config.key_vault_url:
                logger.info("Initializing Key Vault client", 
                          vault_url=self.config.key_vault_url)
                self.secret_client = SecretClient(
                    vault_url=self.config.key_vault_url,
                    credential=self.credential
                )
                
                # Retrieve function key from Key Vault
                try:
                    secret = await asyncio.to_thread(
                        self.secret_client.get_secret, "function-key"
                    )
                    self._function_key = secret.value
                    logger.info("Successfully retrieved function key from Key Vault")
                except Exception as e:
                    logger.warning("Failed to retrieve function key from Key Vault", 
                                 error=str(e))

            # Use function key from config if not retrieved from Key Vault
            if not self._function_key and self.config.function_key:
                self._function_key = self.config.function_key
                logger.info("Using function key from configuration")

            # Initialize HTTP client with enhanced DNS and connection handling
            import ssl
            
            # Create SSL context for Azure endpoints
            ssl_context = ssl.create_default_context()
            ssl_context.check_hostname = True
            ssl_context.verify_mode = ssl.CERT_REQUIRED
            
            # Create HTTP client using the new method
            await self._create_http_client_with_ssl()

            # Initialize rate limiter
            self.throttler = Throttler(
                rate_limit=self.config.rate_limit_requests,
                period=60,  # per minute
                retry_interval=1.0,
            )

            logger.info("Function App client initialized successfully")

        except Exception as e:
            logger.error("Failed to initialize Function App client", error=str(e))
            raise

    async def close(self) -> None:
        """Close the HTTP client and clean up resources."""
        if self.http_client:
            await self.http_client.aclose()
            logger.info("Function App client closed")

    async def call_function(self, function_name: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        """
        Call a specific Azure Function with the given payload.
        
        Args:
            function_name: Name of the function to call (e.g., "MDEAutomator")
            payload: JSON payload to send to the function
            
        Returns:
            Response data from the function
            
        Raises:
            ValueError: If the function name is unknown
            httpx.HTTPError: If the HTTP request fails
            Exception: For other errors during function execution
        """
        # Ensure HTTP client is valid for current event loop
        await self.ensure_http_client()

        # Validate payload if enabled
        if self.config.enable_request_validation:
            self._validate_payload(function_name, payload)

        # Get function URL
        try:
            url = self.config.get_function_url(function_name)
        except ValueError as e:
            logger.error("Invalid function name", function_name=function_name)
            raise

        # Pre-check DNS resolution to avoid httpx DNS issues
        try:
            from urllib.parse import urlparse
            import socket
            import asyncio
            
            parsed_url = urlparse(url)
            hostname = parsed_url.hostname
            port = parsed_url.port or (443 if parsed_url.scheme == 'https' else 80)
            
            # Test DNS resolution asynchronously
            loop = asyncio.get_event_loop()
            addresses = await loop.getaddrinfo(
                hostname, port, 
                family=socket.AF_UNSPEC,
                type=socket.SOCK_STREAM
            )
            logger.debug(f"DNS resolution successful for {hostname}: {len(addresses)} addresses")
            
        except asyncio.TimeoutError:
            logger.warning(f"DNS resolution timeout for {hostname}")
        except socket.gaierror as dns_e:
            logger.error(f"DNS resolution failed for {hostname}: GAI error {dns_e.errno}")
            raise Exception(f"DNS resolution failed for {hostname}: {str(dns_e)}")
        except Exception as dns_e:
            logger.warning(f"DNS pre-check failed for {hostname}: {str(dns_e)}")
            # Continue anyway and let httpx handle it

        # Prepare headers
        headers = {}
        if self._function_key:
            headers["x-functions-key"] = self._function_key

        logger.info(
            "Calling Azure Function",
            function_name=function_name,
            url=url,
            payload_size=len(str(payload)),
        )

        try:
            # Apply rate limiting
            async with self.throttler:
                # Execute request with retry logic
                async for attempt in AsyncRetrying(
                    stop=stop_after_attempt(self.config.max_retries),
                    wait=wait_exponential(
                        multiplier=self.config.retry_delay,
                        min=self.config.retry_delay,
                        max=60,
                    ),
                    retry=retry_if_exception_type((httpx.TimeoutException, httpx.ConnectError)),
                    reraise=True,
                ):
                    with attempt:
                        response = await self.http_client.post(
                            url=url,
                            json=payload,
                            headers=headers,
                        )

                        # Check for HTTP errors
                        response.raise_for_status()

                        # Parse response
                        try:
                            result = response.json()
                        except Exception as e:
                            logger.error(
                                "Failed to parse response JSON",
                                function_name=function_name,
                                response_text=response.text[:1000],
                                error=str(e),
                            )
                            raise ValueError(f"Invalid JSON response: {str(e)}")

                        logger.info(
                            "Function call completed successfully",
                            function_name=function_name,
                            status_code=response.status_code,
                            response_size=len(response.text),
                        )

                        return result

        except httpx.HTTPStatusError as e:
            logger.error(
                "Function call failed with HTTP error",
                function_name=function_name,
                status_code=e.response.status_code,
                response_text=e.response.text[:1000],
                error=str(e),
            )
            
            # Try to extract error details from response
            try:
                error_details = e.response.json()
                error_message = error_details.get("message", str(e))
            except:
                error_message = f"HTTP {e.response.status_code}: {e.response.text[:500]}"
            
            raise Exception(f"Function call failed: {error_message}")

        except Exception as e:
            logger.error(
                "Function call failed with unexpected error",
                function_name=function_name,
                error=str(e),
                exc_info=True,
            )
            raise

    def _validate_payload(self, function_name: str, payload: Dict[str, Any]) -> None:
        """
        Validate the payload for a specific function call.
        
        Args:
            function_name: Name of the function
            payload: Payload to validate
            
        Raises:
            ValueError: If the payload is invalid
        """
        # Common validations
        if not isinstance(payload, dict):
            raise ValueError("Payload must be a dictionary")

        # Function-specific validations
        if function_name in ["MDEDispatcher", "MDEOrchestrator"]:
            device_ids = payload.get("DeviceIds", [])
            if device_ids and len(device_ids) > self.config.max_device_ids_per_request:
                raise ValueError(
                    f"Too many device IDs: {len(device_ids)} > {self.config.max_device_ids_per_request}"
                )

        elif function_name == "MDETIManager":
            # Validate threat indicator counts
            for key in ["Sha1s", "Sha256s", "IPs", "URLs"]:
                indicators = payload.get(key, [])
                if indicators and len(indicators) > self.config.max_indicators_per_request:
                    raise ValueError(
                        f"Too many {key}: {len(indicators)} > {self.config.max_indicators_per_request}"
                    )

        elif function_name == "MDEHunter":
            queries = payload.get("Queries", [])
            if queries and len(queries) > 10:  # Limit concurrent queries
                raise ValueError(f"Too many queries: {len(queries)} > 10")

        # Validate TenantId is present for most functions
        if function_name != "MDEProfiles" and not payload.get("TenantId"):
            logger.warning("TenantId not provided", function_name=function_name)

        logger.debug("Payload validation passed", function_name=function_name)

    async def health_check(self) -> bool:
        """
        Perform a health check against the Function Apps.
        
        Returns:
            True if the health check passes, False otherwise
        """
        try:
            # Simple health check using a lightweight function
            payload = {
                "TenantId": "",
                "Function": "GetTenantIds"
            }
            
            result = await self.call_function("MDEAutoDB", payload)  # Fixed: Use MDEAutoDB instead of MDEAutomator
            
            if isinstance(result, dict):
                logger.info("Health check passed")
                return True
            else:
                logger.warning("Health check returned unexpected result", result=result)
                return False
                
        except Exception as e:
            logger.error("Health check failed", error=str(e))
            return False

    async def ensure_http_client(self) -> None:
        """Ensure HTTP client is valid for the current event loop."""
        try:
            # Check if the current http_client is valid for this event loop
            if self.http_client is None or self.http_client.is_closed:
                await self._create_http_client()
        except Exception as e:
            logger.warning(f"HTTP client validation failed, recreating: {e}")
            await self._create_http_client()

    async def _create_http_client(self) -> None:
        """Create a new HTTP client for the current event loop."""
        try:
            # Close existing client if any
            if self.http_client and not self.http_client.is_closed:
                await self.http_client.aclose()
        except:
            pass  # Ignore errors when closing old client
        
        # Create new HTTP client
        self.http_client = httpx.AsyncClient(
            timeout=httpx.Timeout(self.config.request_timeout),
            limits=httpx.Limits(
                max_connections=100,
                max_keepalive_connections=20,
            ),
            headers={
                "User-Agent": "MDEAutomator-MCP-Server/1.0.0",
                "Content-Type": "application/json",
            },
        )

    async def _create_http_client_with_ssl(self) -> None:
        """Create a new HTTP client with SSL configuration for initialization."""
        try:
            # Close existing client if any
            if self.http_client and not self.http_client.is_closed:
                await self.http_client.aclose()
        except:
            pass  # Ignore errors when closing old client
        
        # Create SSL context
        import ssl
        ssl_context = ssl.create_default_context()
        ssl_context.check_hostname = True
        ssl_context.verify_mode = ssl.CERT_REQUIRED
        
        # Create new HTTP client with full SSL configuration
        self.http_client = httpx.AsyncClient(
            timeout=httpx.Timeout(
                connect=30.0,
                read=self.config.request_timeout,
                write=30.0,
                pool=30.0,
            ),
            limits=httpx.Limits(
                max_connections=50,
                max_keepalive_connections=10,
                keepalive_expiry=30.0,
            ),
            headers={
                "User-Agent": "MDEAutomator-MCP-Server/1.0.0",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Accept-Encoding": "gzip, deflate",
                "Connection": "keep-alive",
            },
            verify=ssl_context,
            # Disable HTTP/2 to avoid potential issues
            http2=False,
        )

    async def cleanup(self) -> None:
        """Clean up resources and close HTTP client."""
        if self.http_client:
            try:
                await self.http_client.aclose()
                logger.info("HTTP client cleaned up successfully")
            except Exception as e:
                logger.warning(f"Error during HTTP client cleanup: {e}")
            finally:
                self.http_client = None
