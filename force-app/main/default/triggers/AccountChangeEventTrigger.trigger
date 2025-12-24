trigger AccountChangeEventTrigger on AccountChangeEvent (after insert) {
    UHT_CDC_Router.route(Trigger.new);
}