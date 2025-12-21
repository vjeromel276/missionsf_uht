public with sharing class UHT_CDC_Router {

    public static void route(List<SObject> events) {
        if (events == null || events.isEmpty()) {
            return;
        }

        SObject first = events[0];
        String typeName = first.getSObjectType().getDescribe().getName();
        // Example: 'AccountChangeEvent' -> 'Account'
        String entityName = typeName.removeEnd('ChangeEvent');

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
