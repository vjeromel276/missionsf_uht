trigger OpportunityChangeEventTrigger on OpportunityChangeEvent (after insert) {
UHT_CDC_Router.route(Trigger.new);
}