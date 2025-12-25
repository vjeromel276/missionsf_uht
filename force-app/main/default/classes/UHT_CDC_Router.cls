/**
 * UHT_CDC_Router
 * 
 * Routes CDC events to the appropriate handler.
 * Called by dynamically deployed CDC triggers.
 */
global with sharing class UHT_CDC_Router {

    global static void route(List<SObject> events) {
        if (events == null || events.isEmpty()) {
            return;
        }

        SObject first = events[0];
        String typeName = first.getSObjectType().getDescribe().getName();
        
        // Extract object API name from ChangeEvent type
        // e.g., 'AccountChangeEvent' -> 'Account'
        // e.g., 'MyObject__ChangeEvent' -> 'MyObject__c'
        String entityName = UHT_NamingHelper.getObjectApiName(typeName);

        // CDC availability check (non-fatal)
        if (!UHT_CDC_Availability.isEnabledForObject(entityName)) {
            System.debug(LoggingLevel.FINE, 'UHT: CDC not enabled for ' + entityName + ', skipping events');
            // CDC not enabled for this object — silently skip
            return;
        }

        // Try object-specific handler first
        String handlerClassName = 'UHT_' + entityName + '_CDC_Handler';
        Type handlerType = Type.forName(handlerClassName);

        UHT_CDC_Handler handler;

        if (handlerType != null) {
            // Use object-specific handler
            handler = (UHT_CDC_Handler) handlerType.newInstance();
        } else {
            // Fallback to generic handler
            handler = new UHT_Generic_CDC_Handler();
        }

        // Process each CDC event
        for (SObject e : events) {
            Map<String, Object> payload = UHT_CDC_EventParser.toPayloadMap(e);
            UHT_CDC_Handler.CDCContext ctx =
                new UHT_CDC_Handler.CDCContext(payload);

            handler.handle(ctx);
        }

        if (handler instanceof UHT_Generic_CDC_Handler) {
            UHT_Generic_CDC_Handler.flush();
        }
    }
}