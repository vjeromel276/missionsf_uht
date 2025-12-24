trigger ContactChangeEventTrigger on ContactChangeEvent (after insert) {
	UHT_CDC_Router.route(Trigger.new);
}