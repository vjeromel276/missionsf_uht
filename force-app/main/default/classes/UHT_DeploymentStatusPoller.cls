/**
 * UHT_DeploymentStatusPoller
 * 
 * Queueable job that polls Metadata API for deployment completion.
 * Chains itself until deployment succeeds or fails.
 */
public with sharing class UHT_DeploymentStatusPoller implements Queueable, Database.AllowsCallouts {

    private Id logRecordId;
    private String deploymentId;
    private String sessionId;
    private Integer pollCount;

    private static final Integer MAX_POLLS = 20;        // Max polling attempts
    private static final Integer POLL_INTERVAL_MS = 2000; // 2 seconds between polls

    public UHT_DeploymentStatusPoller(Id logRecordId, String deploymentId, String sessionId) {
        this.logRecordId = logRecordId;
        this.deploymentId = deploymentId;
        this.sessionId = sessionId;
        this.pollCount = 0;
    }

    // Constructor with poll count for chaining
    public UHT_DeploymentStatusPoller(Id logRecordId, String deploymentId, String sessionId, Integer pollCount) {
        this.logRecordId = logRecordId;
        this.deploymentId = deploymentId;
        this.sessionId = sessionId;
        this.pollCount = pollCount;
    }

    public void execute(QueueableContext context) {
        pollCount++;

        try {
            // Check deployment status
            MetadataService.DeployResult result = 
                UHT_TriggerDeploymentService.checkDeployStatus(deploymentId, sessionId);

            if (result.done) {
                // Deployment finished - update log
                handleDeploymentComplete(result);
            } else {
                // Still in progress - chain another poll
                if (pollCount < MAX_POLLS) {
                    chainNextPoll();
                } else {
                    handleTimeout();
                }
            }

        } catch (Exception e) {
            handleError(e.getMessage());
        }
    }

    /**
     * Handle successful or failed deployment completion
     */
    private void handleDeploymentComplete(MetadataService.DeployResult result) {
        missionsf__UHT_Deployment_Log__c log = new missionsf__UHT_Deployment_Log__c(
            Id = logRecordId,
            missionsf__Completed_At__c = Datetime.now()
        );

        if (result.success) {
            log.missionsf__Status__c = 'Success';
            log.missionsf__Error_Message__c = null;
        } else {
            log.missionsf__Status__c = 'Failed';
            log.missionsf__Error_Message__c = extractErrorMessage(result);
        }

        update log;
    }

    /**
     * Extract error message from deployment result
     */
    private String extractErrorMessage(MetadataService.DeployResult result) {
        String errorMsg = '';

        if (result.details != null && result.details.componentFailures != null) {
            for (MetadataService.DeployMessage failure : result.details.componentFailures) {
                if (failure.problem != null) {
                    errorMsg += failure.fullName + ': ' + failure.problem + '\n';
                }
            }
        }

        if (String.isBlank(errorMsg)) {
            errorMsg = 'Deployment failed. Check Salesforce Setup > Deployment Status for details.';
        }

        // Truncate if too long
        if (errorMsg.length() > 32000) {
            errorMsg = errorMsg.substring(0, 32000);
        }

        return errorMsg;
    }

    /**
     * Chain another polling job
     */
    private void chainNextPoll() {
        // Small delay before next poll (Queueable doesn't have built-in delay)
        // In production, you might use a Scheduled Job for longer intervals
        System.enqueueJob(
            new UHT_DeploymentStatusPoller(logRecordId, deploymentId, sessionId, pollCount)
        );
    }

    /**
     * Handle polling timeout
     */
    private void handleTimeout() {
        missionsf__UHT_Deployment_Log__c log = new missionsf__UHT_Deployment_Log__c(
            Id = logRecordId,
            missionsf__Status__c = 'Timeout',
            missionsf__Error_Message__c = 'Deployment status polling timed out after ' + MAX_POLLS + ' attempts. Check Setup > Deployment Status manually.',
            missionsf__Completed_At__c = Datetime.now()
        );
        update log;
    }

    /**
     * Handle unexpected errors
     */
    private void handleError(String errorMessage) {
        missionsf__UHT_Deployment_Log__c log = new missionsf__UHT_Deployment_Log__c(
            Id = logRecordId,
            missionsf__Status__c = 'Failed',
            missionsf__Error_Message__c = 'Polling error: ' + errorMessage,
            missionsf__Completed_At__c = Datetime.now()
        );
        update log;
    }
}