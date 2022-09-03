import sequtils
# low-level c2nim MQTTClient.h generated wrapper for libpaho-mqtt3c.so
import MQTTClient

type MQTTError* = object of Exception

type MQTTStatus* = enum
  BadQOS = -9,
  BadStructure = -8,
  TopicnameTruncated = -7,
  NullParameter = -6,
  BadUTF8 = -5,
  MaxMessagesInflight = -4,
  Disconnected = -3,
  PersistenceError = -2,
  Failure = -1,
  Success = 0

type QOS* {.pure.} = enum
  AtMostOnce = 0,
  AtLeastOnce = 1,
  ExactlyOnce = 2

const
  QOS0* = QOS.AtMostOnce
  QOS1* = QOS.AtLeastOnce
  QOS2* = QOS.ExactlyOnce

type MQTTPersistenceType* = enum
  Default = 0,
  None = 1,
  User = 2

type MQTTMessage* = object
  payload*: string
  qos*: QOS
  retained*: bool  

type MQTTDeliveryToken* = MQTTClient_deliveryToken

# Helper to create a string from a cstring+len
proc `$`(cs: cstring, len: int): string =
  result = newString(len)
  copyMem(addr(result[0]), cs, len)

# check a return code and if not Success, raise an MQTTError
proc rcCheck(rc: cint) {.raises: [MQTTError].} =
  let status = MQTTStatus(rc)
  if status != MQTTStatus.Success and status != MQTTStatus.TopicnameTruncated:
    raise newException(MQTTError, $status)

#define MQTTClient_connectOptions_initializer { {'M', 'Q', 'T', 'C'}, 4, 60, 1, 1, NULL, NULL, NULL, 30, 20, NULL, 0, NULL, 0}
proc newConnectOptions*(): MQTTClient_connectOptions =
  result.struct_id = ['M','Q','T','C'] 
  result.struct_version = 4
  result.keepAliveInterval = 60
  result.cleansession = 1
  result.reliable = 1
  result.will = nil
  result.username = nil
  result.password = nil
  result.connectTimeout = 30
  result.retryInterval = 20
  result.ssl = nil
  result.serverURIcount = 0
  result.serverURIs = nil
  result.MQTTVersion = 0

#define MQTTClient_message_initializer { {'M', 'Q', 'T', 'M'}, 0, 0, NULL, 0, 0, 0, 0 }
proc MQTTClient_message_initializer*(): MQTTClient_message =
  result.struct_id = ['M','Q','T','M'] 
  # rest of struct is zero'd

proc newClient*(address, clientId: string, persistenceType: MQTTPersistenceType = Default, persistenceContext: pointer = nil): MQTTClient {.raises: [MQTTError].} =
  rcCheck MQTTClient_create(addr result, address, clientId, cint persistenceType, persistenceContext)

proc connect*(client: MQTTClient, connectOptions: var MQTTClient_connectOptions) {.raises: [MQTTError].} =
  rcCheck MQTTClient_connect(client, addr connectOptions)

proc disconnect*(client: MQTTClient, timeout: cint) {.raises: [MQTTError].} =
  rcCheck MQTTClient_disconnect(client, timeout)

proc getVersionInfo*(): seq[tuple[name: string, value: string]] {.raises: [].} =
  var nameValues = cast[ptr array[100, MQTTClient_nameValue]](MQTTClient_getVersionInfo())
  var i = 0
  result = @[]
  while nameValues[i].name != nil:
    result.add(($nameValues[i].name, $nameValues[i].value))
    inc(i)

proc isConnected*(client: MQTTClient): bool =
  MQTTClient_isConnected(client) != 0

proc publish*(client: MQTTClient, topicName: string, payload: string,
              qos: QOS, retained: bool): MQTTDeliveryToken {.raises: [MQTTError].} = 
  let payloadlen = cint payload.len
  var payload = cstring(payload)
  rcCheck MQTTClient_publish(client, topicName, payloadlen, payload, cint qos, cint retained, addr result)

proc publishMessage*(client: MQTTClient, topicName: string,
                     msg: MQTTMessage): MQTTDeliveryToken {.raises: [MQTTError].} =
  var cmsg = MQTTClient_message_initializer()
  cmsg.payload = cstring(msg.payload)
  cmsg.payloadlen = cint len msg.payload
  cmsg.qos = cint msg.qos
  cmsg.retained = cint msg.retained
  rcCheck MQTTClient_publishMessage(client, topicName, addr cmsg, addr result)
    
proc receive*(client: MQTTClient, topicName: var string, message: var MQTTMessage,
              timeout: culong): bool {.raises: [MQTTError].} =
  var cTopicName: cstring
  var topicLen: cint
  var cmessage: ptr MQTTClient_message
  try:
    rcCheck MQTTClient_receive(client, addr cTopicName, addr topicLen, addr cmessage, timeout)
    topicName = cTopicName $ topicLen
    result = cmessage.isNil # timed out?
  finally:
    if cmessage != nil:
      message.payload = cast[cstring](cmessage.payload) $ cmessage.payloadlen
      message.qos = QOS cmessage.qos
      message.retained = cmessage.retained != 0
      MQTTClient_freeMessage(addr cmessage)
    MQTTClient_free(cTopicName)

type MessageArrived* = proc (topicName: string; message: MQTTMessage): cint
type DeliveryComplete* = proc (dt: MQTTClient_deliveryToken)
type ConnectionLost* = proc (cause: string)

type CallbackContext = object
  connectionLost: ConnectionLost
  messageArrived: MessageArrived
  deliveryComplete: DeliveryComplete

proc connectionLost(context: pointer, cause: cstring) {.cdecl.} =
  var context = cast[ptr CallbackContext](context)
  if context.connectionLost != nil:
    var cause = $cause
    context.connectionLost(cause)

proc messageArrived(context: pointer, topicName: cstring, topicLen: cint, cmessage: ptr MQTTClient_message): cint {.cdecl.} =
  var context = cast[ptr CallbackContext](context)
  if context.messageArrived != nil:
    # length is only sent if the string contains nulls, otherwise it is a null-terminated cstring
    var topic = if topicLen > 0: topicName $ topicLen
      else: $topicName
    var message = MQTTMessage()
    if cmessage != nil:
      message.payload = cast[cstring](cmessage.payload) $ cmessage.payloadlen
      message.qos = QOS cmessage.qos
      message.retained = cmessage.retained != 0
    result = context.messageArrived(topic, message)

proc deliveryComplete(context: pointer, dt: MQTTDeliveryToken) {.cdecl.} =
  var context = cast[ptr CallbackContext](context)
  if context.deliveryComplete != nil:
    context.deliveryComplete(dt)

# global holding context callbacks
var context = CallbackContext()

proc setCallbacks*(client: MQTTClient,
                   cl: ConnectionLost,
                   ma: MessageArrived,
                   dc: DeliveryComplete) {.raises: [MQTTError, Exception].} =
  context.connectionLost = cl
  context.messageArrived = ma
  context.deliveryComplete = dc
  rcCheck MQTTClient_setCallbacks(client, addr context, connectionLost, messageArrived, deliveryComplete)

proc subscribe*(client: MQTTClient, topic: string, qos: QOS) {.raises: [MQTTError].} =
  rcCheck MQTTClient_subscribe(client, topic, cint qos)

proc subscribeMany*(client: MQTTClient, topic: openarray[string], qos: openarray[QOS]) {.raises: [MQTTError, Exception].} =
  # copy into C compatible types
  let ctopic = system.allocCStringArray(topic)
  var cqos: seq[cint] = @[]
  for q in qos:
    add(cqos, cint q)
  try:
    rcCheck MQTTClient_subscribeMany(client, cint topic.len, ctopic, addr cqos[0])
  finally:
    system.deallocCStringArray(ctopic)

proc unsubscribe*(client: MQTTClient, topic: string) {.raises: [MQTTError].} =
  rcCheck MQTTClient_unsubscribe(client, topic)

proc unsubscribeMany*(client: MQTTClient, topic: openarray[string]) {.raises: [MQTTError, Exception].} =
  let ctopic = system.allocCStringArray(topic)
  try:
    rcCheck MQTTClient_unsubscribeMany(client, cint topic.len, ctopic)
  finally:
    system.deallocCStringArray(ctopic)

proc waitForCompletion*(client: MQTTClient, 
                                   dt: MQTTDeliveryToken, 
                                   timeout: culong) {.raises: [MQTTError] .} =
  rcCheck MQTTClient_waitForCompletion(client, dt, timeout)

proc getPendingDeliveryTokens*(client: MQTTClient): seq[MQTTDeliveryToken] {.raises: [MQTTError] .} =
  result = @[]
  var ltokens: ptr MQTTClient_deliveryToken
  rcCheck MQTTClient_getPendingDeliveryTokens(client, addr ltokens)
  if ltokens == nil: return # none pending
  var i = 0
  let tokens = cast[ptr array[0..20_000, MQTTClient_deliveryToken]](ltokens)
  while tokens[i] != -1:
    result.add(tokens[i])
    inc(i)
  try:
    MQTTClient_free(ltokens)
  except:
    discard

proc mqttYield*() =
  MQTTClient_yield()
  
proc destroy*(client: MQTTClient) =
  var c = client
  MQTTClient_destroy(addr c)
