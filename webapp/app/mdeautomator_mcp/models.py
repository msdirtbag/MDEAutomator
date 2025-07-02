"""
Pydantic models for request/response validation.

This module defines the data models used for validating requests and responses
between the MCP server and Azure Function Apps.
"""

from typing import Any, Dict, List, Optional, Union
from pydantic import BaseModel, Field, validator


class DeviceActionRequest(BaseModel):
    """Base model for device action requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    device_ids: List[str] = Field(default_factory=list, description="List of device IDs")
    all_devices: bool = Field(False, description="Apply action to all devices")

    @validator("device_ids")
    def validate_device_ids(cls, v, values):
        """Validate device IDs."""
        if not values.get("all_devices", False) and not v:
            raise ValueError("Either device_ids must be provided or all_devices must be True")
        return v


class DeviceIsolationRequest(DeviceActionRequest):
    """Model for device isolation requests."""
    isolation_type: str = Field("selective", description="Type of isolation (selective/full)")

    @validator("isolation_type")
    def validate_isolation_type(cls, v):
        """Validate isolation type."""
        if v not in ["selective", "full"]:
            raise ValueError("isolation_type must be 'selective' or 'full'")
        return v


class LiveResponseRequest(BaseModel):
    """Model for live response requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    device_ids: List[str] = Field(..., description="List of device IDs")
    script_name: Optional[str] = Field(None, description="Name of script to execute")
    file_name: Optional[str] = Field(None, description="Name of file to put/get")
    file_path: Optional[str] = Field(None, description="Path of file on device")
    file_content: Optional[str] = Field(None, description="Base64 encoded file content")
    target_filename: Optional[str] = Field(None, description="Target filename for upload")


class ThreatIndicatorRequest(BaseModel):
    """Model for threat indicator requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    indicator_type: str = Field(..., description="Type of indicator (file/ip/url/cert)")
    sha1_hashes: List[str] = Field(default_factory=list, description="List of SHA1 hashes")
    sha256_hashes: List[str] = Field(default_factory=list, description="List of SHA256 hashes")
    ip_addresses: List[str] = Field(default_factory=list, description="List of IP addresses")
    urls: List[str] = Field(default_factory=list, description="List of URLs/domains")
    cert_thumbprints: List[str] = Field(default_factory=list, description="List of certificate thumbprints")

    @validator("indicator_type")
    def validate_indicator_type(cls, v):
        """Validate indicator type."""
        if v not in ["file", "ip", "url", "cert"]:
            raise ValueError("indicator_type must be one of: file, ip, url, cert")
        return v

    @validator("sha1_hashes", "sha256_hashes")
    def validate_hashes(cls, v):
        """Validate hash formats."""
        for hash_value in v:
            if not isinstance(hash_value, str) or not hash_value.strip():
                raise ValueError("Hashes must be non-empty strings")
        return v

    @validator("ip_addresses")
    def validate_ip_addresses(cls, v):
        """Validate IP address format (basic validation)."""
        import ipaddress
        for ip in v:
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                raise ValueError(f"Invalid IP address: {ip}")
        return v

    @validator("urls")
    def validate_urls(cls, v):
        """Validate URL format (basic validation)."""
        for url in v:
            if not isinstance(url, str) or not url.strip():
                raise ValueError("URLs must be non-empty strings")
        return v


class HuntingRequest(BaseModel):
    """Model for hunting query requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    queries: List[str] = Field(..., description="List of KQL queries to execute")
    hunt_name: Optional[str] = Field(None, description="Name for scheduled hunt")
    schedule: Optional[str] = Field(None, description="Schedule for hunt execution")
    hunt_id: Optional[str] = Field(None, description="Hunt ID for result retrieval")

    @validator("queries")
    def validate_queries(cls, v):
        """Validate hunting queries."""
        if not v:
            raise ValueError("At least one query must be provided")
        for query in v:
            if not isinstance(query, str) or not query.strip():
                raise ValueError("Queries must be non-empty strings")
        return v


class IncidentRequest(BaseModel):
    """Model for incident management requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    incident_id: Optional[str] = Field(None, description="Incident ID")
    status: Optional[str] = Field(None, description="Incident status")
    assigned_to: Optional[str] = Field(None, description="Assigned user")
    classification: Optional[str] = Field(None, description="Incident classification")
    determination: Optional[str] = Field(None, description="Incident determination")
    custom_tags: List[str] = Field(default_factory=list, description="Custom tags")
    description: Optional[str] = Field(None, description="Incident description")
    display_name: Optional[str] = Field(None, description="Incident display name")
    severity: Optional[str] = Field(None, description="Incident severity")
    resolving_comment: Optional[str] = Field(None, description="Resolution comment")
    summary: Optional[str] = Field(None, description="Incident summary")
    comment: Optional[str] = Field(None, description="Comment to add")

    @validator("status")
    def validate_status(cls, v):
        """Validate incident status."""
        if v and v not in ["active", "resolved", "redirected"]:
            raise ValueError("status must be one of: active, resolved, redirected")
        return v

    @validator("classification")
    def validate_classification(cls, v):
        """Validate incident classification."""
        valid_classifications = [
            "unknown", "falsePositive", "truePositive", "informationalExpectedActivity"
        ]
        if v and v not in valid_classifications:
            raise ValueError(f"classification must be one of: {valid_classifications}")
        return v

    @validator("determination")
    def validate_determination(cls, v):
        """Validate incident determination."""
        valid_determinations = [
            "unknown", "apt", "malware", "securityPersonnel", "securityTesting",
            "unwantedSoftware", "other", "multiStagedAttack", "compromisedAccount",
            "phishing", "maliciousUserActivity", "notMalicious", "notEnoughDataToValidate",
            "confirmedUserActivity", "lineOfBusinessApplication"
        ]
        if v and v not in valid_determinations:
            raise ValueError(f"determination must be one of: {valid_determinations}")
        return v

    @validator("severity")
    def validate_severity(cls, v):
        """Validate incident severity."""
        if v and v not in ["unknown", "informational", "low", "medium", "high"]:
            raise ValueError("severity must be one of: unknown, informational, low, medium, high")
        return v


class CustomDetectionRequest(BaseModel):
    """Model for custom detection rule requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    rule_id: Optional[str] = Field(None, description="Detection rule ID")
    rule_definition: Optional[Dict[str, Any]] = Field(None, description="Rule definition JSON")

    @validator("rule_definition")
    def validate_rule_definition(cls, v):
        """Validate rule definition structure."""
        if v is not None:
            required_fields = ["displayName", "description", "queryText"]
            for field in required_fields:
                if field not in v:
                    raise ValueError(f"rule_definition must contain '{field}' field")
        return v


class ActionStatusRequest(BaseModel):
    """Model for action status requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    action_id: str = Field(..., description="Machine action ID")


class FileInfoRequest(BaseModel):
    """Model for file information requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    sha1_hashes: List[str] = Field(..., description="List of SHA1 hashes to query")

    @validator("sha1_hashes")
    def validate_sha1_hashes(cls, v):
        """Validate SHA1 hash format."""
        for hash_value in v:
            if not isinstance(hash_value, str) or len(hash_value) != 40:
                raise ValueError(f"Invalid SHA1 hash format: {hash_value}")
        return v


class IPInfoRequest(BaseModel):
    """Model for IP information requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    ip_addresses: List[str] = Field(..., description="List of IP addresses to query")

    @validator("ip_addresses")
    def validate_ip_addresses(cls, v):
        """Validate IP address format."""
        import ipaddress
        for ip in v:
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                raise ValueError(f"Invalid IP address: {ip}")
        return v


class URLInfoRequest(BaseModel):
    """Model for URL information requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    urls: List[str] = Field(..., description="List of URLs/domains to query")

    @validator("urls")
    def validate_urls(cls, v):
        """Validate URL format."""
        for url in v:
            if not isinstance(url, str) or not url.strip():
                raise ValueError("URLs must be non-empty strings")
        return v


class StopQuarantineRequest(BaseModel):
    """Model for stop and quarantine file requests."""
    tenant_id: str = Field(..., description="Tenant ID for the operation")
    sha1_hash: str = Field(..., description="SHA1 hash of file to stop and quarantine")
    all_devices: bool = Field(True, description="Apply to all devices")

    @validator("sha1_hash")
    def validate_sha1_hash(cls, v):
        """Validate SHA1 hash format."""
        if not isinstance(v, str) or len(v) != 40:
            raise ValueError(f"Invalid SHA1 hash format: {v}")
        return v
