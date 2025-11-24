# This simulates calling an actual Azure Automation webhook

## Example webhook URL (replace with your actual webhook URL)
$webhookUrl = "[WEBHOOK_URL_HERE]"

## Webhook payload
$payload = @{
    User = ""
    StorageAccountName = "" 
    ContainerName = ""
    BlobName = ""
} | ConvertTo-Json

$headers = @{
 'Content-Type' = 'application/json'
}

Invoke-WebRequest -Uri $webhookUrl -Method Post -Body $payload -Headers $headers
