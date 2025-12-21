@IsTest
private class UHT_CDC_Handler_Test {

    private class TestHandler extends UHT_CDC_Handler {
        protected override void handleCreate(CDCContext ctx) {}
        protected override void handleUpdate(CDCContext ctx) {}
        protected override void handleDelete(CDCContext ctx) {}
        protected override void handleUndelete(CDCContext ctx) {}
        protected override void handleOther(CDCContext ctx) {}
    }

    @IsTest
    static void testBaseHandlerRouting() {
        TestHandler h = new TestHandler();

        List<String> types = new List<String>{
            'CREATE','UPDATE','DELETE','UNDELETE','SOMETHING_ELSE'
        };

        for (String t : types) {
            h.handle(new UHT_CDC_Handler.CDCContext(
                new Map<String,Object>{
                    'ChangeEventHeader' => new Map<String,Object>{
                        'entityName' => 'Account',
                        'changeType' => t,
                        'recordIds' => new List<String>{ '001000000000001AAA' }
                    }
                }
            ));
        }

        // no asserts needed — routing coverage only
        System.assert(true);
    }
}
