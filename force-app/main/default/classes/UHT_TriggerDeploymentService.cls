/**
 * UHT_TriggerDeploymentService
 * 
 * Orchestrates the deployment of CDC triggers to subscriber orgs via Metadata API.
 * 
 * Dependencies:
 *   - Zippex (https://github.com/pdalcol/Zippex)
 *   - MetadataService (https://github.com/financialforcedev/apex-mdapi)
 *   - Remote Site Setting for org's Metadata API endpoint
 */
public with sharing class UHT_TriggerDeploymentService {

    // Metadata API namespace
    private static final String METADATA_NS = 'http://soap.sforce.com/2006/04/metadata';
    private static final String API_VERSION = '65.0';

    /**
     * Deploy a CDC trigger for the specified object
     * Must be called from synchronous context (UserInfo.getSessionId() returns null in async)
     * 
     * @param objectApiName The object to create a trigger for (e.g., 'Contact')
     * @return The deployment log record ID for status tracking
     */
    public static Id deployTrigger(String objectApiName) {
        // Validate input
        if (String.isBlank(objectApiName)) {
            throw new DeploymentException('Object API name is required');
        }

        // Check if trigger already exists
        if (triggerExists(objectApiName)) {
            throw new DeploymentException('Trigger already exists for ' + objectApiName);
        }

        // Get session ID (must be synchronous context)
        String sessionId = UserInfo.getSessionId();
        if (String.isBlank(sessionId)) {
            throw new DeploymentException('Session ID not available. Deploy must be initiated from user context.');
        }

        // Generate trigger files
        UHT_TriggerGenerator.TriggerFiles files = UHT_TriggerGenerator.generate(objectApiName);

        // ============================================
        // CALLOUT FIRST - before any DML
        // ============================================
        
        // Build the deployment zip
        Blob zipBlob = buildDeploymentZip(files);

        // Deploy via Metadata API (this is the callout)
        String deploymentId = deployToMetadataApi(zipBlob, sessionId);

        // ============================================
        // DML AFTER CALLOUT
        // ============================================

        // Create deployment log record with deployment ID already known
        missionsf__UHT_Deployment_Log__c logRecord = new missionsf__UHT_Deployment_Log__c(
            missionsf__Object_Name__c = objectApiName,
            missionsf__Trigger_Name__c = files.triggerName,
            missionsf__Status__c = 'In Progress',
            missionsf__Deployment_Id__c = deploymentId,
            missionsf__Initiated_At__c = Datetime.now()
        );
        insert logRecord;

        // Queue the status poller
        System.enqueueJob(new UHT_DeploymentStatusPoller(logRecord.Id, deploymentId, sessionId));

        return logRecord.Id;
    }

    /**
     * Check if a trigger already exists for this object
     */
    private static Boolean triggerExists(String objectApiName) {
        String triggerName = objectApiName + 'ChangeEventTrigger';
        
        // Query ApexTrigger via Tooling API would be more accurate,
        // but for simplicity we check our deployment log
        List<missionsf__UHT_Deployment_Log__c> existing = [
            SELECT Id 
            FROM missionsf__UHT_Deployment_Log__c
            WHERE missionsf__Object_Name__c = :objectApiName
              AND missionsf__Status__c = 'Success'
            LIMIT 1
        ];
        
        return !existing.isEmpty();
    }

    /**
     * Build the deployment zip file containing:
     *   - triggers/[TriggerName].trigger
     *   - triggers/[TriggerName].trigger-meta.xml
     *   - package.xml
     */
    private static Blob buildDeploymentZip(UHT_TriggerGenerator.TriggerFiles files) {
        Zippex zip = new Zippex();

        // Add trigger file
        String triggerPath = 'triggers/' + files.triggerName + '.trigger';
        zip.addFile(triggerPath, Blob.valueOf(files.triggerCode), null);

        // Add trigger meta.xml
        String metaPath = 'triggers/' + files.triggerName + '.trigger-meta.xml';
        zip.addFile(metaPath, Blob.valueOf(files.metaXml), null);

        // Add package.xml
        String packageXml = generatePackageXml(files.triggerName);
        zip.addFile('package.xml', Blob.valueOf(packageXml), null);

        return zip.getZipArchive();
    }

    /**
     * Generate package.xml for the deployment
     */
    private static String generatePackageXml(String triggerName) {
        return '<?xml version="1.0" encoding="UTF-8"?>\n'
             + '<Package xmlns="' + METADATA_NS + '">\n'
             + '    <types>\n'
             + '        <members>' + triggerName + '</members>\n'
             + '        <name>ApexTrigger</name>\n'
             + '    </types>\n'
             + '    <version>' + API_VERSION + '</version>\n'
             + '</Package>';
    }

    /**
     * Deploy the zip to Metadata API
     * Returns the async deployment ID
     */
    private static String deployToMetadataApi(Blob zipBlob, String sessionId) {
        // Create Metadata API service
        MetadataService.MetadataPort service = new MetadataService.MetadataPort();
        service.SessionHeader = new MetadataService.SessionHeader_element();
        service.SessionHeader.sessionId = sessionId;

        // Set endpoint to current org
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        service.endpoint_x = baseUrl + '/services/Soap/m/' + API_VERSION;

        // Configure deployment options
        MetadataService.DeployOptions deployOptions = new MetadataService.DeployOptions();
        deployOptions.allowMissingFiles = false;
        deployOptions.autoUpdatePackage = false;
        deployOptions.checkOnly = false;
        deployOptions.ignoreWarnings = true;
        deployOptions.performRetrieve = false;
        deployOptions.purgeOnDelete = false;
        deployOptions.rollbackOnError = true;
        deployOptions.runTests = new String[]{};
        deployOptions.singlePackage = true;
        deployOptions.testLevel = 'NoTestRun'; // For CDC triggers, tests run separately

        // Deploy
        MetadataService.AsyncResult result = service.deploy(
            EncodingUtil.base64Encode(zipBlob),
            deployOptions
        );

        return result.id;
    }

    /**
     * Check deployment status (called by poller)
     */
    public static MetadataService.DeployResult checkDeployStatus(String deploymentId, String sessionId) {
        MetadataService.MetadataPort service = new MetadataService.MetadataPort();
        service.SessionHeader = new MetadataService.SessionHeader_element();
        service.SessionHeader.sessionId = sessionId;

        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        service.endpoint_x = baseUrl + '/services/Soap/m/' + API_VERSION;

        return service.checkDeployStatus(deploymentId, true);
    }

    /**
     * Get deployment status for UI
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getDeploymentStatus(Id logRecordId) {
        missionsf__UHT_Deployment_Log__c log = [
            SELECT missionsf__Object_Name__c,
                   missionsf__Trigger_Name__c,
                   missionsf__Status__c,
                   missionsf__Error_Message__c,
                   missionsf__Deployment_Id__c,
                   missionsf__Initiated_At__c,
                   missionsf__Completed_At__c
            FROM missionsf__UHT_Deployment_Log__c
            WHERE Id = :logRecordId
            LIMIT 1
        ];

        return new Map<String, Object>{
            'objectName' => log.missionsf__Object_Name__c,
            'triggerName' => log.missionsf__Trigger_Name__c,
            'status' => log.missionsf__Status__c,
            'errorMessage' => log.missionsf__Error_Message__c,
            'deploymentId' => log.missionsf__Deployment_Id__c,
            'initiatedAt' => log.missionsf__Initiated_At__c,
            'completedAt' => log.missionsf__Completed_At__c
        };
    }

        /**
     * Deploy a CDC trigger with provided session ID
     * Used when session ID is obtained externally (e.g., from Named Credential context)
     */
    public static Id deployTriggerWithSession(String objectApiName, String sessionId) {
        // Validate input
        if (String.isBlank(objectApiName)) {
            throw new DeploymentException('Object API name is required');
        }
        
        if (String.isBlank(sessionId)) {
            throw new DeploymentException('Session ID is required');
        }

        // Check if trigger already exists
        if (triggerExists(objectApiName)) {
            throw new DeploymentException('Trigger already exists for ' + objectApiName);
        }

        // Generate trigger files
        UHT_TriggerGenerator.TriggerFiles files = UHT_TriggerGenerator.generate(objectApiName);

        // Build the deployment zip
        Blob zipBlob = buildDeploymentZip(files);

        // Deploy via Metadata API
        String deploymentId = deployToMetadataApi(zipBlob, sessionId);

        // Create deployment log record
        missionsf__UHT_Deployment_Log__c logRecord = new missionsf__UHT_Deployment_Log__c(
            missionsf__Object_Name__c = objectApiName,
            missionsf__Trigger_Name__c = files.triggerName,
            missionsf__Status__c = 'In Progress',
            missionsf__Deployment_Id__c = deploymentId,
            missionsf__Initiated_At__c = Datetime.now()
        );
        insert logRecord;

        // Queue the status poller
        System.enqueueJob(new UHT_DeploymentStatusPoller(logRecord.Id, deploymentId, sessionId));

        return logRecord.Id;
    }

    /**
     * Entry point for LWC - deploy trigger for object
     */
    @AuraEnabled
    public static Id deployTriggerForObject(String objectApiName) {
        return deployTrigger(objectApiName);
    }

    public class DeploymentException extends Exception {}
}