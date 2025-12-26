/**
 * UHT_AdminController
 * 
 * Apex controller for the UHT Admin Console LWC.
 * Provides methods to:
 *   - List available objects for CDC tracking
 *   - Get fields for a given object
 *   - Check CDC enablement status
 *   - Load/save tracking configuration
 */
public with sharing class UHT_AdminController {

    // =========================================================================
    // WRAPPER CLASSES
    // =========================================================================

    /**
     * Wrapper for object information displayed in the UI
     */
    public class ObjectInfo {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public Boolean cdcEnabled;
        @AuraEnabled public Boolean isTracked;
        @AuraEnabled public Boolean isCustom;

        public ObjectInfo(String apiName, String label, Boolean cdcEnabled, Boolean isTracked, Boolean isCustom) {
            this.apiName = apiName;
            this.label = label;
            this.cdcEnabled = cdcEnabled;
            this.isTracked = isTracked;
            this.isCustom = isCustom;
        }
    }

    /**
     * Wrapper for field information displayed in the UI
     */
    public class FieldInfo {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String type;
        @AuraEnabled public Boolean isTracked;

        public FieldInfo(String apiName, String label, String type, Boolean isTracked) {
            this.apiName = apiName;
            this.label = label;
            this.type = type;
            this.isTracked = isTracked;
        }
    }

    /**
     * Wrapper for the complete tracking configuration
     */
    public class TrackingConfiguration {
        @AuraEnabled public List<ObjectInfo> objects;
        @AuraEnabled public Map<String, List<FieldInfo>> fieldsByObject;

        public TrackingConfiguration() {
            this.objects = new List<ObjectInfo>();
            this.fieldsByObject = new Map<String, List<FieldInfo>>();
        }
    }

    // =========================================================================
    // PUBLIC METHODS - @AuraEnabled
    // =========================================================================

    /**
     * Get all available objects that could potentially be tracked.
     * Returns standard objects known to support CDC + all custom objects.
     * CDC status shows capability (whether the object supports CDC), not actual enablement.
     * Users should verify CDC is enabled in Setup before tracking.
     */
    @AuraEnabled
    public static List<ObjectInfo> getAvailableObjects() {
        // Load currently tracked objects for comparison
        Set<String> trackedObjectNames = getTrackedObjectNames();

        List<ObjectInfo> results = new List<ObjectInfo>();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        // Standard objects that commonly support CDC (lowercase for comparison)
        Set<String> cdcCapableStandardObjects = new Set<String>{
            'account', 'contact', 'lead', 'opportunity', 'case', 'task', 'event',
            'campaign', 'campaignmember', 'contract', 'order', 'orderitem',
            'product2', 'pricebook2', 'pricebookentry', 'asset', 'quote',
            'quotelineitem', 'servicecontract', 'entitlement', 'workorder',
            'workorderlineitem', 'serviceappointment', 'user'
        };

        for (String objName : globalDescribe.keySet()) {
            Schema.SObjectType sot = globalDescribe.get(objName);
            Schema.DescribeSObjectResult dsr = sot.getDescribe();

            // Skip non-queryable, non-createable system objects
            if (!dsr.isQueryable() || !dsr.isCreateable()) {
                continue;
            }

            Boolean isCustom = dsr.isCustom();
            Boolean includeObject = false;

            // Include custom objects (they can have CDC enabled)
            if (isCustom && !objName.endsWithIgnoreCase('__mdt') && 
                !objName.endsWithIgnoreCase('__e') && 
                !objName.endsWithIgnoreCase('__x') &&
                !objName.endsWithIgnoreCase('__Share') &&
                !objName.endsWithIgnoreCase('__History') &&
                !objName.endsWithIgnoreCase('__Feed')) {
                includeObject = true;
            }

            // Include known CDC-capable standard objects (compare lowercase)
            if (!isCustom && cdcCapableStandardObjects.contains(objName.toLowerCase())) {
                includeObject = true;
            }

            if (includeObject) {
                // Use the proper API name from describe (preserves correct casing)
                String properApiName = dsr.getName();
                // Check CDC capability via Schema (not actual enablement)
                Boolean cdcCapable = UHT_CDC_Availability.isEnabledForObject(properApiName);
                Boolean isTracked = trackedObjectNames.contains(properApiName);

                results.add(new ObjectInfo(
                    properApiName,
                    dsr.getLabel(),
                    cdcCapable,  // This indicates capability, not actual enablement
                    isTracked,
                    isCustom
                ));
            }
        }

        // Sort alphabetically by label
        results.sort(new ObjectInfoComparator());

        return results;
    }

    /**
     * Get all trackable fields for a given object.
     */
    @AuraEnabled(cacheable=true)
    public static List<FieldInfo> getObjectFields(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            throw new AuraHandledException('Object API name is required');
        }

        // Load currently tracked fields for this object
        Set<String> trackedFieldNames = getTrackedFieldNames(objectApiName);

        List<FieldInfo> results = new List<FieldInfo>();

        // Try to get the object - handle case sensitivity
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            // Try lowercase
            sot = Schema.getGlobalDescribe().get(objectApiName.toLowerCase());
        }
        if (sot == null) {
            throw new AuraHandledException('Object not found: ' + objectApiName);
        }

        Map<String, Schema.SObjectField> fieldsMap = sot.getDescribe().fields.getMap();

        // Field types that can be tracked via CDC
        Set<Schema.DisplayType> trackableTypes = new Set<Schema.DisplayType>{
            Schema.DisplayType.STRING,
            Schema.DisplayType.TEXTAREA,
            Schema.DisplayType.EMAIL,
            Schema.DisplayType.PHONE,
            Schema.DisplayType.URL,
            Schema.DisplayType.PICKLIST,
            Schema.DisplayType.MULTIPICKLIST,
            Schema.DisplayType.BOOLEAN,
            Schema.DisplayType.INTEGER,
            Schema.DisplayType.DOUBLE,
            Schema.DisplayType.CURRENCY,
            Schema.DisplayType.PERCENT,
            Schema.DisplayType.DATE,
            Schema.DisplayType.DATETIME,
            Schema.DisplayType.REFERENCE,
            Schema.DisplayType.ID
        };

        // System fields to exclude
        Set<String> excludedFields = new Set<String>{
            'Id', 'IsDeleted', 'CreatedById', 'CreatedDate', 
            'LastModifiedById', 'LastModifiedDate', 'SystemModstamp',
            'LastActivityDate', 'LastViewedDate', 'LastReferencedDate'
        };

        for (String fieldName : fieldsMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldsMap.get(fieldName).getDescribe();

            // Skip system fields
            if (excludedFields.contains(dfr.getName())) {
                continue;
            }

            // Skip formula fields (CDC doesn't capture them)
            if (dfr.isCalculated()) {
                continue;
            }

            // Skip non-trackable field types
            if (!trackableTypes.contains(dfr.getType())) {
                continue;
            }

            // Skip fields that aren't updateable (read-only)
            if (!dfr.isUpdateable()) {
                continue;
            }

            Boolean isTracked = trackedFieldNames.contains(dfr.getName());

            results.add(new FieldInfo(
                dfr.getName(),
                dfr.getLabel(),
                dfr.getType().name(),
                isTracked
            ));
        }

        // Sort alphabetically by label
        results.sort(new FieldInfoComparator());

        return results;
    }

    /**
     * Check if CDC is enabled for a specific object.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean isCDCEnabled(String objectApiName) {
        return UHT_CDC_Availability.isEnabledForObject(objectApiName);
    }

    /**
     * Get the complete tracking configuration (objects + fields).
     */
    @AuraEnabled(cacheable=true)
    public static TrackingConfiguration getTrackedConfiguration() {
        TrackingConfiguration config = new TrackingConfiguration();

        // Get all available objects with their tracking status
        config.objects = getAvailableObjects();

        // Pre-load fields for tracked objects only (performance optimization)
        for (ObjectInfo obj : config.objects) {
            if (obj.isTracked || obj.cdcEnabled) {
                config.fieldsByObject.put(obj.apiName, getObjectFields(obj.apiName));
            }
        }

        return config;
    }

    /**
     * Save tracking configuration using delta approach.
     * Activates newly selected items, deactivates removed items.
     * Also deploys CDC triggers for newly activated objects via Named Credential.
     * 
     * @param objectsToActivate List of object API names to activate
     * @param objectsToDeactivate List of object API names to deactivate
     * @param fieldsToActivate Map of object API name -> list of field API names to activate
     * @param fieldsToDeactivate Map of object API name -> list of field API names to deactivate
     * @return JSON string with deployment info
     */
    @AuraEnabled
    public static String saveTrackedConfiguration(
        List<String> objectsToActivate, 
        List<String> objectsToDeactivate,
        Map<String, List<String>> fieldsToActivate, 
        Map<String, List<String>> fieldsToDeactivate
    ) {
        // Validate inputs - convert nulls to empty collections
        if (objectsToActivate == null) objectsToActivate = new List<String>();
        if (objectsToDeactivate == null) objectsToDeactivate = new List<String>();
        if (fieldsToActivate == null) fieldsToActivate = new Map<String, List<String>>();
        if (fieldsToDeactivate == null) fieldsToDeactivate = new Map<String, List<String>>();

        // Track deployment results
        List<String> triggerDeploymentIds = new List<String>();
        List<String> triggerErrors = new List<String>();

        // =========================================================================
        // STEP 1: Deploy triggers for newly activated objects via Named Credential
        // This callout happens FIRST before any DML
        // =========================================================================
        for (String objectApiName : objectsToActivate) {
            try {
                String deployLogId = deployTriggerViaNamedCredential(objectApiName);
                if (deployLogId != null) {
                    triggerDeploymentIds.add(deployLogId);
                }
            } catch (Exception e) {
                // Capture error but continue with MDT deployment
                triggerErrors.add(objectApiName + ': ' + e.getMessage());
            }
        }

        // =========================================================================
        // STEP 2: Build and deploy custom metadata
        // NOTE: fullName requires namespace prefix to identify the managed CMT type.
        // Field references do NOT need namespace prefix - Salesforce resolves them
        // automatically when running inside a managed package context.
        // =========================================================================
        Metadata.DeployContainer container = new Metadata.DeployContainer();

        // Process objects to ACTIVATE
        for (String objectApiName : objectsToActivate) {
            Metadata.CustomMetadata objMd = new Metadata.CustomMetadata();
            objMd.fullName = 'missionsf__UHT_Tracked_Object__mdt.' + sanitizeForMetadata(objectApiName);
            objMd.label = getMetadataLabel(objectApiName);

            Metadata.CustomMetadataValue objApiNameValue = new Metadata.CustomMetadataValue();
            objApiNameValue.field = 'missionsf__ObjectApiName__c';
            objApiNameValue.value = objectApiName;
            objMd.values.add(objApiNameValue);

            Metadata.CustomMetadataValue objActiveValue = new Metadata.CustomMetadataValue();
            objActiveValue.field = 'missionsf__IsActive__c';
            objActiveValue.value = true;
            objMd.values.add(objActiveValue);

            container.addMetadata(objMd);
        }

        // Process objects to DEACTIVATE
        for (String objectApiName : objectsToDeactivate) {
            Metadata.CustomMetadata objMd = new Metadata.CustomMetadata();
            objMd.fullName = 'missionsf__UHT_Tracked_Object__mdt.' + sanitizeForMetadata(objectApiName);
            objMd.label = getMetadataLabel(objectApiName);

            Metadata.CustomMetadataValue objApiNameValue = new Metadata.CustomMetadataValue();
            objApiNameValue.field = 'missionsf__ObjectApiName__c';
            objApiNameValue.value = objectApiName;
            objMd.values.add(objApiNameValue);

            Metadata.CustomMetadataValue objActiveValue = new Metadata.CustomMetadataValue();
            objActiveValue.field = 'missionsf__IsActive__c';
            objActiveValue.value = false;
            objMd.values.add(objActiveValue);

            container.addMetadata(objMd);
        }

        // Process fields to ACTIVATE
        for (String objectApiName : fieldsToActivate.keySet()) {
            List<String> fields = fieldsToActivate.get(objectApiName);
            for (String fieldApiName : fields) {
                Metadata.CustomMetadata fieldMd = new Metadata.CustomMetadata();
                fieldMd.fullName = 'missionsf__UHT_Tracked_Field__mdt.' + 
                    sanitizeForMetadata(objectApiName) + '_' + sanitizeForMetadata(fieldApiName);
                fieldMd.label = getMetadataLabel(objectApiName) + ' ' + getMetadataLabel(fieldApiName);

                Metadata.CustomMetadataValue fieldObjValue = new Metadata.CustomMetadataValue();
                fieldObjValue.field = 'missionsf__ObjectApiName__c';
                fieldObjValue.value = objectApiName;
                fieldMd.values.add(fieldObjValue);

                Metadata.CustomMetadataValue fieldNameValue = new Metadata.CustomMetadataValue();
                fieldNameValue.field = 'missionsf__FieldApiName__c';
                fieldNameValue.value = fieldApiName;
                fieldMd.values.add(fieldNameValue);

                Metadata.CustomMetadataValue fieldActiveValue = new Metadata.CustomMetadataValue();
                fieldActiveValue.field = 'missionsf__IsActive__c';
                fieldActiveValue.value = true;
                fieldMd.values.add(fieldActiveValue);

                container.addMetadata(fieldMd);
            }
        }

        // Process fields to DEACTIVATE
        for (String objectApiName : fieldsToDeactivate.keySet()) {
            List<String> fields = fieldsToDeactivate.get(objectApiName);
            for (String fieldApiName : fields) {
                Metadata.CustomMetadata fieldMd = new Metadata.CustomMetadata();
                fieldMd.fullName = 'missionsf__UHT_Tracked_Field__mdt.' + 
                    sanitizeForMetadata(objectApiName) + '_' + sanitizeForMetadata(fieldApiName);
                fieldMd.label = getMetadataLabel(objectApiName) + ' ' + getMetadataLabel(fieldApiName);

                Metadata.CustomMetadataValue fieldObjValue = new Metadata.CustomMetadataValue();
                fieldObjValue.field = 'missionsf__ObjectApiName__c';
                fieldObjValue.value = objectApiName;
                fieldMd.values.add(fieldObjValue);

                Metadata.CustomMetadataValue fieldNameValue = new Metadata.CustomMetadataValue();
                fieldNameValue.field = 'missionsf__FieldApiName__c';
                fieldNameValue.value = fieldApiName;
                fieldMd.values.add(fieldNameValue);

                Metadata.CustomMetadataValue fieldActiveValue = new Metadata.CustomMetadataValue();
                fieldActiveValue.field = 'missionsf__IsActive__c';
                fieldActiveValue.value = false;
                fieldMd.values.add(fieldActiveValue);

                container.addMetadata(fieldMd);
            }
        }

        // Deploy the metadata
        Id mdtDeployJobId = Metadata.Operations.enqueueDeployment(container, new MetadataDeployCallback());

        // Build response
        Map<String, Object> response = new Map<String, Object>{
            'mdtDeploymentId' => String.valueOf(mdtDeployJobId),
            'triggerDeploymentIds' => triggerDeploymentIds,
            'triggerErrors' => triggerErrors
        };

        return JSON.serialize(response);
    }

    /**
     * Deploy a trigger via Named Credential REST endpoint.
     * This solves the Lightning session restriction by routing through OAuth.
     */
    private static String deployTriggerViaNamedCredential(String objectApiName) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:UHT_Self_Callout/services/apexrest/missionsf/uht/deploy');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, String>{ 'objectApiName' => objectApiName }));
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        if (res.getStatusCode() == 200) {
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Boolean success = (Boolean) result.get('success');
            
            if (success) {
                return (String) result.get('deploymentLogId');
            } else {
                String errorMsg = (String) result.get('errorMessage');
                throw new AuraHandledException(errorMsg);
            }
        } else {
            throw new AuraHandledException('Trigger deployment failed: HTTP ' + res.getStatusCode() + ' - ' + res.getBody());
        }
    }

    // =========================================================================
    // PRIVATE HELPER METHODS
    // =========================================================================

    /**
     * Get set of currently tracked object names from custom metadata
     */
    private static Set<String> getTrackedObjectNames() {
        Set<String> names = new Set<String>();
        for (missionsf__UHT_Tracked_Object__mdt obj : [
            SELECT missionsf__ObjectApiName__c 
            FROM missionsf__UHT_Tracked_Object__mdt 
            WHERE IsActive__c = true
        ]) {
            names.add(obj.missionsf__ObjectApiName__c);
        }
        return names;
    }

    /**
     * Get set of currently tracked field names for a specific object
     */
    private static Set<String> getTrackedFieldNames(String objectApiName) {
        Set<String> names = new Set<String>();
        for (missionsf__UHT_Tracked_Field__mdt fld : [
            SELECT missionsf__FieldApiName__c 
            FROM missionsf__UHT_Tracked_Field__mdt 
            WHERE missionsf__ObjectApiName__c = :objectApiName
              AND IsActive__c = true
        ]) {
            names.add(fld.missionsf__FieldApiName__c);
        }
        return names;
    }

    /**
     * Sanitize an API name for use as metadata record Name
     * Strips namespace prefix and __c suffix
     * 
     * Examples:
     *   missionsf__Test_Object__c -> Test_Object
     *   missionsf__Test__c -> Test
     *   Account -> Account
     *   Industry -> Industry
     */
    private static String sanitizeForMetadata(String input) {
        if (String.isBlank(input)) {
            return 'Unknown';
        }
        
        String result = input.trim();
        
        // Step 1: Strip __c, __r, __e, __x, __b suffixes FIRST
        // (Must happen before namespace check to avoid treating object name as namespace)
        if (result.endsWith('__c') || result.endsWith('__r') || 
            result.endsWith('__e') || result.endsWith('__x') || 
            result.endsWith('__b')) {
            result = result.substring(0, result.length() - 3);
        } else if (result.endsWith('__mdt')) {
            result = result.substring(0, result.length() - 5);
        }
        
        // Step 2: Strip namespace prefix (e.g., missionsf__)
        if (result.contains('__')) {
            Integer idx = result.indexOf('__');
            String beforeDouble = result.substring(0, idx);
            // If it looks like a namespace (letters/numbers, starts with letter)
            if (beforeDouble.isAlphanumeric() && beforeDouble.length() > 0 && beforeDouble.substring(0, 1).isAlpha()) {
                result = result.substring(idx + 2);
            }
        }
        
        // Step 3: Ensure doesn't start with number
        if (result.length() > 0 && result.substring(0, 1).isNumeric()) {
            result = 'X' + result;
        }
        
        // Step 4: Truncate to 40 characters if needed
        if (result.length() > 40) {
            result = result.substring(0, 40);
        }
        
        return String.isBlank(result) ? 'Unknown' : result;
    }

    /**
     * Get the Label for a metadata record
     * Converts the sanitized name to human-readable format
     * 
     * Examples:
     *   missionsf__Test_Object__c -> Test Object
     *   missionsf__Test__c -> Test
     *   Account -> Account
     *   Industry -> Industry
     */
    private static String getMetadataLabel(String input) {
        String name = sanitizeForMetadata(input);
        return name.replace('_', ' ');
    }

    // =========================================================================
    // COMPARATORS FOR SORTING
    // =========================================================================

    private class ObjectInfoComparator implements Comparator<ObjectInfo> {
        public Integer compare(ObjectInfo o1, ObjectInfo o2) {
            if (o1.label == null && o2.label == null) return 0;
            if (o1.label == null) return 1;
            if (o2.label == null) return -1;
            return o1.label.compareTo(o2.label);
        }
    }

    private class FieldInfoComparator implements Comparator<FieldInfo> {
        public Integer compare(FieldInfo f1, FieldInfo f2) {
            if (f1.label == null && f2.label == null) return 0;
            if (f1.label == null) return 1;
            if (f2.label == null) return -1;
            return f1.label.compareTo(f2.label);
        }
    }

    // =========================================================================
    // METADATA DEPLOY CALLBACK
    // =========================================================================

    /**
     * Callback handler for metadata deployment results
     */
    public class MetadataDeployCallback implements Metadata.DeployCallback {
        public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
            if (result.status == Metadata.DeployStatus.Succeeded) {
                System.debug('UHT: Configuration metadata deployed successfully');
            } else {
                System.debug(LoggingLevel.ERROR, 'UHT: Configuration deployment failed: ' + result);
            }
        }
    }
}