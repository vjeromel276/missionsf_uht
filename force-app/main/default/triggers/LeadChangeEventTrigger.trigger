trigger LeadChangeEventTrigger on LeadChangeEvent (after insert) {
    UHT_CDC_Router.route(Trigger.new);
}