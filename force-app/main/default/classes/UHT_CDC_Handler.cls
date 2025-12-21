public abstract class UHT_CDC_Handler {

    public class CDCContext {
        public String entityName;
        public String changeType;
        public Id recordId;
        public Map<String, Object> rawPayload;

        public CDCContext(Map<String, Object> payload) {
            Object hdr = payload.get('ChangeEventHeader');
            if (hdr != null) {
                Map<String, Object> header =
                    (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(hdr));

                entityName = (String) header.get('entityName');
                changeType = (String) header.get('changeType');

                Object rid = header.get('recordIds');
                if (rid instanceof List<Object> && !((List<Object>)rid).isEmpty()) {
                    recordId = (Id) ((List<Object>)rid)[0];
                }
            }

        }
    }

    public void handle(CDCContext ctx) {
        if (ctx == null || ctx.changeType == null) {
            return;
        }

        if (ctx.changeType == 'CREATE') {
            handleCreate(ctx);
        } else if (ctx.changeType == 'UPDATE') {
            handleUpdate(ctx);
        } else if (ctx.changeType == 'DELETE') {
            handleDelete(ctx);
        } else if (ctx.changeType == 'UNDELETE') {
            handleUndelete(ctx);
        } else {
            handleOther(ctx);
        }
    }

    protected virtual void handleCreate(CDCContext ctx) {}
    protected virtual void handleUpdate(CDCContext ctx) {}
    protected virtual void handleDelete(CDCContext ctx) {}
    protected virtual void handleUndelete(CDCContext ctx) {}
    protected virtual void handleOther(CDCContext ctx) {}
}
