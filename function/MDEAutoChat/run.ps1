# MDEAutoChat 

using namespace System.Net

param($Request)

# Helper function for parameter validation
function Test-NullOrEmpty {
    param (
        [string]$Value,
        [string]$ParamName
    )
    if ([string]::IsNullOrEmpty($Value)) {
        throw "Missing required parameter: $ParamName"
    }
}

# Function to initialize PSAISuite and Azure AI Foundry
function Initialize-PSAISuite {
    param()
    
    try {
        Write-Host "Initializing PSAISuite module..."
        
        # Configure Azure AI Foundry credentials from environment variables
        $azureAIKey = [System.Environment]::GetEnvironmentVariable('AZURE_AI_KEY', 'Process')
        $azureAIEndpoint = [System.Environment]::GetEnvironmentVariable('AZURE_AI_ENDPOINT', 'Process')
        
        if ([string]::IsNullOrEmpty($azureAIKey)) {
            throw "Azure AI Foundry configuration missing. Please set AZURE_AI_KEY environment variable."
        }
        
        if ([string]::IsNullOrEmpty($azureAIEndpoint)) {
            throw "Azure AI Foundry configuration missing. Please set AZURE_AI_ENDPOINT environment variable."
        }
        
        # Set environment variables for PSAISuite
        $env:AzureAIKey = $azureAIKey
        $env:AzureAIEndpoint = $azureAIEndpoint
        
        return $true
    }
    catch {
        Write-Error "Failed to initialize PSAISuite: $($_.Exception.Message)"
        throw
    }
}

# Function to call Azure AI Foundry using PSAISuite
function Invoke-AzureAIFoundryChat {
    param (
        [string]$Message,
        [string]$SystemPrompt = "You are a helpful AI assistant for Microsoft Defender for Endpoint operations and security analysis.",
        [string]$Context = "",
        [string]$Model = "",
        [int]$MaxTokens = 1000,
        [double]$Temperature = 0.7
    )
      try {        
        
        Write-Host "Calling Azure AI Foundry via PSAISuite..."
        
        # Build the message with system prompt and user message
        $promptText = ""
        
        # Add system prompt first
        if (-not [string]::IsNullOrEmpty($SystemPrompt)) {
            $promptText += $SystemPrompt + "`n`n"
        }
        
        # Add the user message
        $promptText += $Message
        Write-Host "Prompt length: $($promptText.Length) characters"
        
        # Use New-ChatMessage with -Prompt parameter as shown in PSAISuite docs
        $chatMessage = New-ChatMessage -Prompt $promptText
        
        # Prepare model string for PSAISuite (azureai:model-name format)
        $psaiModel = "azureai:$Model"
        Write-Host "Invoking chat completion with model: $psaiModel"
        
        # Call with enhanced retry logic and debugging
        $maxRetries = 3
        $retryDelay = 2
        $lastException = $null
        $response = $null
          for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                Write-Host "Attempt $attempt of $maxRetries..."
                
                if (-not [string]::IsNullOrEmpty($Context)) {
                    Write-Host "Context length: $($Context.Length) characters"
                    $response = $Context | Invoke-ChatCompletion -Messages $chatMessage -Model $psaiModel -Verbose
                } else {
                    $response = Invoke-ChatCompletion -Messages $chatMessage -Model $psaiModel -Verbose
                }
                
                if ($response) {
                    Write-Host "Response received successfully on attempt $attempt"
                    break
                }
                else {
                    Write-Warning "Null response received on attempt $attempt"
                }
            }
            catch {
                $lastException = $_
                Write-Error "Chat completion attempt $attempt failed: $($_.Exception.Message)"
                Write-Error "Exception type: $($_.Exception.GetType().Name)"
                Write-Error "Stack trace: $($_.ScriptStackTrace)"
                
                if ($attempt -lt $maxRetries) {
                    Write-Warning "Retrying in $retryDelay seconds..."
                    Start-Sleep -Seconds $retryDelay
                    $retryDelay *= 2 
                }
            }
        }
        
        if ($lastException -and -not $response) {
            throw "All retry attempts failed. Last error: $($lastException.Exception.Message)"
        }
        
        if (-not $response) {
            throw "No response received from Azure AI Foundry after $maxRetries attempts"
        }
        $responseContent = $null
        $usage = $null
        
        
        if ($response.PSObject.Properties['Response']) {
            $responseContent = $response.Response

            if ($response.PSObject.Properties['Usage']) {
                $usage = $response.Usage
                Write-Host "Found usage information"
            }
        }
        else {
            if ($response -is [string]) {
                Write-Host "Response is a string"
                $responseContent = $response
            }
            elseif ($response.PSObject.Properties['Content']) {
                Write-Host "Response has Content property"
                $responseContent = $response.Content
            }
            elseif ($response.PSObject.Properties['choices'] -and $response.choices -and $response.choices.Count -gt 0) {
                Write-Host "Response has OpenAI-style choices array"
                $responseContent = $response.choices[0].message.content
                $usage = $response.usage
            }
            else {
                Write-Host "Using response.ToString() as last resort"
                $responseContent = $response.ToString()
            }
        }
        if ([string]::IsNullOrEmpty($responseContent)) {
            Write-Error "Failed to extract response content from PSAISuite response"
            Write-Error "Response type: $($response.GetType().Name)"
            Write-Error "Response properties: $($response.PSObject.Properties.Name -join ', ')"
            throw "Empty response content received from PSAISuite"
        }
        
        Write-Host "Successfully extracted response content. Length: $($responseContent.Length) characters"
        
        # Create standardized response object
        $result = @{
            Status = "Success"
            Response = $responseContent
            Model = $Model
            AuthMethod = "AzureAIFoundry"
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
          # Add usage information if available
        if ($usage) {
            # Handle both OpenAI and PSAISuite usage formats
            if ($usage.prompt_tokens -and $usage.completion_tokens) {
                # Standard OpenAI format
                $result.Usage = @{
                    PromptTokens = $usage.prompt_tokens
                    CompletionTokens = $usage.completion_tokens
                    TotalTokens = $usage.total_tokens
                }
            }
            elseif ($usage.PromptTokens -and $usage.CompletionTokens) {
                # PSAISuite format
                $result.Usage = @{
                    PromptTokens = $usage.PromptTokens
                    CompletionTokens = $usage.CompletionTokens
                    TotalTokens = $usage.TotalTokens
                }
            }
            else {
                # Unknown format, try to extract what we can
                $result.Usage = $usage
            }        }        else {
            # Estimate token usage if not provided (include context in calculation if provided)
            $contextLength = if (-not [string]::IsNullOrEmpty($Context)) { $Context.Length } else { 0 }
            $estimatedPromptTokens = [Math]::Ceiling(($SystemPrompt.Length + $contextLength + $Message.Length) / 4)
            $estimatedCompletionTokens = [Math]::Ceiling($responseContent.Length / 4)
            $result.Usage = @{
                PromptTokens = $estimatedPromptTokens
                CompletionTokens = $estimatedCompletionTokens
                TotalTokens = $estimatedPromptTokens + $estimatedCompletionTokens
            }
        }
        return $result
    }
    catch {
        Write-Error "PSAISuite chat completion failed: $($_.Exception.Message)"
        throw
    }
}

# Function to validate and sanitize input
function Test-ChatInput {
    param (
        [string]$Message
    )
    
    if ([string]::IsNullOrEmpty($Message)) {
        throw "Message content cannot be empty"
    }
    
    if ($Message.Length -gt 8000) {
        throw "Message content exceeds maximum length of 8000 characters"
    }
    
    $blockedPatterns = @(
        "(?i)prompt injection",
        "(?i)ignore previous instructions",
        "(?i)system:",
        "(?i)assistant:"
    )
    
    foreach ($pattern in $blockedPatterns) {
        if ($Message -match $pattern) {
            Write-Warning "Potentially harmful content detected and blocked"
            throw "Message content contains blocked patterns"
        }
    }
    
    return $true
}

# Main execution block
try {
    Write-Host "MDEAutoChat function started - $(Get-Date)"
      
    # Initialize PSAISuite
    Initialize-PSAISuite
     
    # Get request parameters
    $Message = Get-RequestParam -Name "message" -Request $Request
    $SystemPrompt = Get-RequestParam -Name "system_prompt" -Request $Request
    $Context = Get-RequestParam -Name "context" -Request $Request
    $MaxTokens = Get-RequestParam -Name "max_tokens" -Request $Request
    $Temperature = Get-RequestParam -Name "temperature" -Request $Request

    $Model = [System.Environment]::GetEnvironmentVariable('AZURE_AI_MODEL', 'Process')
    if ([string]::IsNullOrEmpty($Model)) {
        $Model = "gpt-4.1"
    }
    $MaxTokens = 3000
    $Temperature = 0.7

    # Validate and sanitize input
    Test-ChatInput -Message $Message
    
    # Set defaults if not provided
    if ([string]::IsNullOrEmpty($SystemPrompt)) {
        $SystemPrompt = "You are an expert AI assistant specializing in Microsoft Defender for Endpoint (MDE) security operations, threat analysis, and incident response. You help security analysts with:
        
        - Analyzing security alerts and incidents
        - Understanding threat indicators and IOCs
        - Interpreting hunting query results
        - Providing remediation guidance
        - Explaining security concepts and best practices
        
        Always provide accurate, actionable information and ask clarifying questions when needed."
    }
    
    Write-Host "Processing chat request"
    Write-Host "Message length: $($Message.Length) characters"
    if (-not [string]::IsNullOrEmpty($Context)) {
        Write-Host "Context length: $($Context.Length) characters"
    }
    $chatResponse = Invoke-AzureAIFoundryChat -Message $Message -SystemPrompt $SystemPrompt -Context $Context -Model $Model -MaxTokens $MaxTokens -Temperature $Temperature
    
    $Result = [HttpStatusCode]::OK
    $Body = $chatResponse | ConvertTo-Json -Depth 100 -Compress
    
    Write-Host "Chat completion successful - Tokens used: $($chatResponse.Usage.TotalTokens)"
}
catch {
    $Result = [HttpStatusCode]::InternalServerError
    $errorResponse = @{
        Status = "Error"
        Message = "Chat completion failed: $($_.Exception.Message)"
        ErrorType = $_.Exception.GetType().Name
        Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $Body = $errorResponse | ConvertTo-Json -Depth 100 -Compress
    Write-Error "MDEAutoChat Error: $($_.Exception.Message)"
    Write-Error "Stack Trace: $($_.ScriptStackTrace)"
}

# Return response
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $Result
    Body = $Body
    Headers = @{
        'Content-Type' = 'application/json'
        'Cache-Control' = 'no-cache'
    }
})

Write-Host "MDEAutoChat function completed - $(Get-Date)"