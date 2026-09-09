package main

import "github.com/slunghq/slung/sdks/go/sdk"

var mapTrigger = sdk.Mapper(parseTrigger)
var runSendHTTPRequests = sdk.Rule(sendHTTPRequests)

//export __slung_source_TriggerSource_descriptor
func sourceDescriptor() uint64 {
	return sdk.Descriptor(`{"name":"TriggerSource","kind":"builtin","builtin":"http","config":{"endpoint":"/api/trigger"},"components":[{"name":"trigger","type_name":"HttpTrigger","mapper":"__slung_map_TriggerSource_trigger","dynamic":false}]}`)
}

//export __slung_component_HttpTrigger_descriptor
func componentDescriptor() uint64 {
	return sdk.Descriptor(`{"name":"HttpTrigger","kind":"struct","fields":["request_id"]}`)
}

//export __slung_rule_send_http_requests_descriptor
func ruleDescriptor() uint64 {
	return sdk.Descriptor(`{"name":"send_http_requests","watch":["TriggerSource::trigger"],"priority":10}`)
}

//export __slung_map_TriggerSource_trigger
func mapTriggerExport(rawPtr, rawLen, outPtr, outLenPtr uint32) int32 {
	return mapTrigger(rawPtr, rawLen, outPtr, outLenPtr)
}

//export __slung_rule_send_http_requests
func sendHTTPRequestsExport() int32 {
	return runSendHTTPRequests()
}
