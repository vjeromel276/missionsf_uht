/**
 * UHT_DeploymentRestService
 * 
 * REST endpoint for trigger deployment that runs with a valid API session.
 * Called via Named Credential from the Admin Controller.
 * 
 * Queues the deployment to avoid callout loop restrictions.
 */
@RestResource(urlMapping='/uht/deploy/*')
global with sharing class UHT_DeploymentRestService {

    /**
     * Get CDC-enabled objects via Tooling API
     * GET /services/apexrest/uht/deploy
     */
    @HttpGet
    global static CDCStatusResult getCDCEnabledObjects() {
        CDCStatusResult result = new CDCStatusResult();
        
        try {
            // Query Tooling API for PlatformEventChannelMember
            String baseUrl = URL.getOrgDomainUrl().toExternalForm();
            String query = 'SELECT Id, SelectedEntity FROM PlatformEventChannelMember';
            String endpoint = baseUrl + '/services/data/v65.0/tooling/query/?q=' + EncodingUtil.urlEncode(query, 'UTF-8');
            
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            req.setHeader('Content-Type', 'application/json');
            
            Http http = new Http();
            HttpResponse res = http.send(req);
            
            if (res.getStatusCode() == 200) {
                Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                List<Object> records = (List<Object>) responseMap.get('records');
                
                Set<String> enabledObjects = new Set<String>();
                for (Object record : records) {
                    Map<String, Object> rec = (Map<String, Object>) record;
                    String selectedEntity = (String) rec.get('SelectedEntity');
                    // SelectedEntity is like "AccountChangeEvent" - extract object name
                    if (selectedEntity != null && selectedEntity.endsWith('ChangeEvent')) {
                        String objectName = selectedEntity.replace('ChangeEvent', '');
                        enabledObjects.add(objectName);
                    }
                }
                
                result.success = true;
                result.enabledObjects = new List<String>(enabledObjects);
            } else {
                result.success = false;
                result.errorMessage = 'Tooling API returned: ' + res.getStatusCode() + ' - ' + res.getBody();
            }
            
        } catch (Exception e) {
            result.success = false;
            result.errorMessage = e.getMessage();
        }
        
        return result;
    }

    /**
     * Deploy a trigger for the specified object
     * POST /services/apexrest/uht/deploy
     * Body: { "objectApiName": "Account" }
     */
    @HttpPost
    global static DeploymentResult deployTrigger() {
        DeploymentResult result = new DeploymentResult();
        
        try {
            // Parse request body
            RestRequest req = RestContext.request;
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());
            String objectApiName = (String) body.get('objectApiName');
            
            if (String.isBlank(objectApiName)) {
                result.success = false;
                result.errorMessage = 'objectApiName is required';
                return result;
            }
            
            // Get session ID now (we have a valid one from Named Credential OAuth)
            String sessionId = UserInfo.getSessionId();
            if (String.isBlank(sessionId)) {
                result.success = false;
                result.errorMessage = 'No valid session ID available';
                return result;
            }
            
            // Queue the deployment - this breaks the callout loop
            Id jobId = System.enqueueJob(new TriggerDeploymentQueueable(objectApiName, sessionId));
            
            result.success = true;
            result.message = 'Deployment queued';
            result.queuedJobId = String.valueOf(jobId);
            
        } catch (Exception e) {
            result.success = false;
            result.errorMessage = e.getMessage();
        }
        
        return result;
    }
    
    /**
     * Response wrapper for CDC status
     */
    global class CDCStatusResult {
        public Boolean success;
        public List<String> enabledObjects;
        public String errorMessage;
    }
    
    /**
     * Response wrapper for deployment
     */
    global class DeploymentResult {
        public Boolean success;
        public String deploymentLogId;
        public String queuedJobId;
        public String message;
        public String errorMessage;
    }
    
    /**
     * Queueable to perform the actual deployment
     * This breaks the callout loop by running asynchronously
     */
    public class TriggerDeploymentQueueable implements Queueable, Database.AllowsCallouts {
        private String objectApiName;
        private String sessionId;
        
        public TriggerDeploymentQueueable(String objectApiName, String sessionId) {
            this.objectApiName = objectApiName;
            this.sessionId = sessionId;
        }
        
        public void execute(QueueableContext context) {
            try {
                // Call the deployment service with the session ID we captured
                Id deployLogId = UHT_TriggerDeploymentService.deployTriggerWithSession(objectApiName, sessionId);
                System.debug('Trigger deployment initiated for ' + objectApiName + ', log ID: ' + deployLogId);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Trigger deployment failed for ' + objectApiName + ': ' + e.getMessage());
            }
        }
    }
}