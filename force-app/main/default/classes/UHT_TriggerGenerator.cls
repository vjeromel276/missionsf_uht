public with sharing class UHT_TriggerGenerator {

    public class TriggerFiles {
        public String triggerCode;
        public String metaXml;
        public String triggerName;
        
        public TriggerFiles(String name, String code, String xml) {
            this.triggerName = name;
            this.triggerCode = code;
            this.metaXml = xml;
        }
    }

    private static final String API_VERSION = '65.0';

    // Namespace prefix for packaged router class
    private static final String NAMESPACE = 'missionsf';

    /**
     * Generate trigger files for a given object
     * @param objectApiName The API name of the object (e.g., 'Contact', 'Opportunity', 'Custom_Object__c')
     * @return TriggerFiles containing triggerName, triggerCode, and metaXml
     */
    public static TriggerFiles generate(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            throw new TriggerGeneratorException('Object API name is required');
        }

        // Sanitize input - remove any whitespace
        objectApiName = objectApiName.trim();

        String triggerName = buildTriggerName(objectApiName);
        String changeEventName = objectApiName + 'ChangeEvent';

        String triggerCode = generateTriggerCode(triggerName, changeEventName);
        String metaXml = generateMetaXml();

        return new TriggerFiles(triggerName, triggerCode, metaXml);
    }

    /**
     * Build trigger name from object API name
     * Handles both standard objects (Account) and custom objects (Custom_Object__c)
     */
    private static String buildTriggerName(String objectApiName) {
        // For custom objects, the ChangeEvent name includes the __c
        // e.g., Custom_Object__c -> Custom_Object__ChangeEvent
        // For standard objects: Account -> AccountChangeEvent
        return objectApiName + 'ChangeEventTrigger';
    }

    /**
     * Generate the trigger source code
     */
    // private static String generateTriggerCode(String triggerName, String changeEventName) {
    //     return 'trigger ' + triggerName + ' on ' + changeEventName + ' (after insert) {\n'
    //          + '    ' + NAMESPACE + '.UHT_CDC_Router.route(Trigger.new);\n'
    //          + '}';
    // }
    private static String generateTriggerCode(String triggerName, String changeEventName) {
        return 'trigger ' + triggerName + ' on ' + changeEventName + ' (after insert) {\n'
             + '    UHT_CDC_Router.route(Trigger.new);\n'
             + '}';
    }

    /**
     * Generate the trigger metadata XML
     */
    private static String generateMetaXml() {
        return '<?xml version="1.0" encoding="UTF-8"?>\n'
             + '<ApexTrigger xmlns="http://soap.sforce.com/2006/04/metadata">\n'
             + '    <apiVersion>' + API_VERSION + '</apiVersion>\n'
             + '    <status>Active</status>\n'
             + '</ApexTrigger>';
    }

    public class TriggerGeneratorException extends Exception {}
}