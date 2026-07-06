-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-- Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- ProvenQueue: proven-queueconn types adapted for the Hybrid Automation Router.
--
-- This module re-exports the proven-queueconn message queue types with
-- HAR-specific semantics.  The core proven-queueconn library defines a
-- generic message queue connector interface; here we map those types to
-- HAR's event dispatch pipeline:
--
--   QueueState  ->  connection lifecycle to downstream automation targets
--   ──────────────────────────────────────
--   Disconnected  ->  target not yet connected (e.g., rpa-elysium offline)
--   Connected     ->  target connection established, ready for dispatch
--   Consuming     ->  HAR receiving events from upstream sources
--   Producing     ->  HAR dispatching events to downstream targets
--   Failed        ->  target connection lost or errored
--
--   MessageState  ->  tracking routed events through delivery
--   ──────────────────────────────────────
--   Pending       ->  event enqueued, awaiting dispatch to target
--   Delivered     ->  event sent to target, awaiting acknowledgement
--   Acknowledged  ->  target confirmed successful processing
--   Rejected      ->  target rejected the event (e.g., validation error)
--   DeadLettered  ->  event exceeded retry limit, moved to dead-letter queue
--   Expired       ->  event TTL elapsed, discarded
--
--   DeliveryGuarantee  ->  configurable per-target
--   ──────────────────────────────────────
--   AtMostOnce   ->  fire-and-forget (low-priority targets)
--   AtLeastOnce  ->  default for rpa-elysium (guaranteed delivery, may duplicate)
--   ExactlyOnce  ->  for idempotent targets with transactional coordination
--
--   QueueOp  ->  HAR dispatch operations
--   ──────────────────────────────────────
--   Publish     ->  HAR sends a routed event to a downstream target
--   Subscribe   ->  HAR receives events from an upstream source
--   Acknowledge ->  HAR acknowledges processing of a received event
--   Reject      ->  HAR rejects a received event
--   Peek        ->  inspect next event without consuming
--   Purge       ->  clear a target's outbound queue (admin operation)
--
-- Tag values MUST match proven-servers exactly:
--   QueueOp:           Publish=0, Subscribe=1, Acknowledge=2, Reject=3,
--                      Peek=4, Purge=5
--   DeliveryGuarantee: AtMostOnce=0, AtLeastOnce=1, ExactlyOnce=2
--   QueueState:        Disconnected=0, Connected=1, Consuming=2,
--                      Producing=3, Failed=4
--   MessageState:      Pending=0, Delivered=1, Acknowledged=2,
--                      Rejected=3, DeadLettered=4, Expired=5
--   QueueError:        ConnectionLost=0, QueueNotFound=1, MessageTooLarge=2,
--                      QuotaExceeded=3, AckTimeout=4, Unauthorized=5,
--                      SerializationError=6

module ProvenQueue

import Data.Bits

%default total

---------------------------------------------------------------------------
-- QueueOp — operations HAR can perform against a target's event queue.
---------------------------------------------------------------------------

||| Operations that HAR can perform against a downstream target's queue.
||| Tag values: Publish=0, Subscribe=1, Acknowledge=2, Reject=3, Peek=4, Purge=5
public export
data QueueOp : Type where
  ||| Publish a routed event to a downstream target (e.g., rpa-elysium).
  Publish     : QueueOp
  ||| Subscribe to receive events from an upstream source.
  Subscribe   : QueueOp
  ||| Acknowledge successful processing of a received event.
  Acknowledge : QueueOp
  ||| Reject a received event, optionally requesting redelivery.
  Reject      : QueueOp
  ||| Inspect the next event without removing it from the queue.
  Peek        : QueueOp
  ||| Remove all messages from a target's outbound queue (admin operation).
  Purge       : QueueOp

public export
Show QueueOp where
  show Publish     = "Publish"
  show Subscribe   = "Subscribe"
  show Acknowledge = "Acknowledge"
  show Reject      = "Reject"
  show Peek        = "Peek"
  show Purge       = "Purge"

||| Convert QueueOp to C-compatible tag value.
public export
queueOpToTag : QueueOp -> Bits8
queueOpToTag Publish     = 0
queueOpToTag Subscribe   = 1
queueOpToTag Acknowledge = 2
queueOpToTag Reject      = 3
queueOpToTag Peek        = 4
queueOpToTag Purge       = 5

||| Convert C tag value back to QueueOp.
public export
tagToQueueOp : Bits8 -> Maybe QueueOp
tagToQueueOp 0 = Just Publish
tagToQueueOp 1 = Just Subscribe
tagToQueueOp 2 = Just Acknowledge
tagToQueueOp 3 = Just Reject
tagToQueueOp 4 = Just Peek
tagToQueueOp 5 = Just Purge
tagToQueueOp _ = Nothing

---------------------------------------------------------------------------
-- DeliveryGuarantee — per-target delivery semantics.
---------------------------------------------------------------------------

||| The delivery guarantee level, configurable per automation target.
||| Tag values: AtMostOnce=0, AtLeastOnce=1, ExactlyOnce=2
public export
data DeliveryGuarantee : Type where
  ||| Fire-and-forget.  Events may be lost but never duplicated.
  ||| Suitable for low-priority monitoring targets.
  AtMostOnce  : DeliveryGuarantee
  ||| Events are guaranteed delivered but may arrive more than once.
  ||| Default for rpa-elysium and other critical automation targets.
  AtLeastOnce : DeliveryGuarantee
  ||| Events are delivered exactly once.  Requires idempotent targets
  ||| or transactional coordination.
  ExactlyOnce : DeliveryGuarantee

public export
Show DeliveryGuarantee where
  show AtMostOnce  = "AtMostOnce"
  show AtLeastOnce = "AtLeastOnce"
  show ExactlyOnce = "ExactlyOnce"

||| Convert DeliveryGuarantee to C-compatible tag value.
public export
deliveryGuaranteeToTag : DeliveryGuarantee -> Bits8
deliveryGuaranteeToTag AtMostOnce  = 0
deliveryGuaranteeToTag AtLeastOnce = 1
deliveryGuaranteeToTag ExactlyOnce = 2

||| Convert C tag value back to DeliveryGuarantee.
public export
tagToDeliveryGuarantee : Bits8 -> Maybe DeliveryGuarantee
tagToDeliveryGuarantee 0 = Just AtMostOnce
tagToDeliveryGuarantee 1 = Just AtLeastOnce
tagToDeliveryGuarantee 2 = Just ExactlyOnce
tagToDeliveryGuarantee _ = Nothing

---------------------------------------------------------------------------
-- QueueState — connection lifecycle to a downstream automation target.
---------------------------------------------------------------------------

||| The lifecycle state of a connection to a downstream automation target.
||| Tag values: Disconnected=0, Connected=1, Consuming=2, Producing=3, Failed=4
public export
data QueueState : Type where
  ||| No connection established to the target (e.g., rpa-elysium offline).
  Disconnected : QueueState
  ||| Connection established and ready for dispatch.
  Connected    : QueueState
  ||| HAR is actively receiving events from this source.
  Consuming    : QueueState
  ||| HAR is actively dispatching events to this target.
  Producing    : QueueState
  ||| Connection to the target has entered a failed state.
  Failed       : QueueState

public export
Show QueueState where
  show Disconnected = "Disconnected"
  show Connected    = "Connected"
  show Consuming    = "Consuming"
  show Producing    = "Producing"
  show Failed       = "Failed"

||| Convert QueueState to C-compatible tag value.
public export
queueStateToTag : QueueState -> Bits8
queueStateToTag Disconnected = 0
queueStateToTag Connected    = 1
queueStateToTag Consuming    = 2
queueStateToTag Producing    = 3
queueStateToTag Failed       = 4

||| Convert C tag value back to QueueState.
public export
tagToQueueState : Bits8 -> Maybe QueueState
tagToQueueState 0 = Just Disconnected
tagToQueueState 1 = Just Connected
tagToQueueState 2 = Just Consuming
tagToQueueState 3 = Just Producing
tagToQueueState 4 = Just Failed
tagToQueueState _ = Nothing

---------------------------------------------------------------------------
-- MessageState — tracking a routed event through the delivery pipeline.
---------------------------------------------------------------------------

||| The lifecycle state of a routed event in the dispatch pipeline.
||| Tag values: Pending=0, Delivered=1, Acknowledged=2, Rejected=3,
|||             DeadLettered=4, Expired=5
public export
data MessageState : Type where
  ||| Event is enqueued and awaiting dispatch to the matched target.
  Pending      : MessageState
  ||| Event has been sent to the target but not yet acknowledged.
  Delivered    : MessageState
  ||| Target confirmed successful processing of the event.
  Acknowledged : MessageState
  ||| Target rejected the event (e.g., payload validation error).
  Rejected     : MessageState
  ||| Event exceeded its retry limit and was moved to the dead-letter queue.
  DeadLettered : MessageState
  ||| Event's TTL has elapsed and it was discarded.
  Expired      : MessageState

public export
Show MessageState where
  show Pending      = "Pending"
  show Delivered    = "Delivered"
  show Acknowledged = "Acknowledged"
  show Rejected     = "Rejected"
  show DeadLettered = "DeadLettered"
  show Expired      = "Expired"

||| Convert MessageState to C-compatible tag value.
public export
messageStateToTag : MessageState -> Bits8
messageStateToTag Pending      = 0
messageStateToTag Delivered    = 1
messageStateToTag Acknowledged = 2
messageStateToTag Rejected     = 3
messageStateToTag DeadLettered = 4
messageStateToTag Expired      = 5

||| Convert C tag value back to MessageState.
public export
tagToMessageState : Bits8 -> Maybe MessageState
tagToMessageState 0 = Just Pending
tagToMessageState 1 = Just Delivered
tagToMessageState 2 = Just Acknowledged
tagToMessageState 3 = Just Rejected
tagToMessageState 4 = Just DeadLettered
tagToMessageState 5 = Just Expired
tagToMessageState _ = Nothing

---------------------------------------------------------------------------
-- QueueError — error categories for dispatch operations.
---------------------------------------------------------------------------

||| Error categories that HAR's dispatch pipeline can encounter.
||| Tag values: ConnectionLost=0, QueueNotFound=1, MessageTooLarge=2,
|||             QuotaExceeded=3, AckTimeout=4, Unauthorized=5,
|||             SerializationError=6
public export
data QueueError : Type where
  ||| The connection to the automation target was lost.
  ConnectionLost     : QueueError
  ||| The specified target queue does not exist.
  QueueNotFound      : QueueError
  ||| The event payload exceeds the maximum allowed size.
  MessageTooLarge    : QueueError
  ||| The target's queue quota has been exceeded.
  QuotaExceeded      : QueueError
  ||| The acknowledgement was not received within the timeout window.
  AckTimeout         : QueueError
  ||| HAR lacks permission to dispatch to this target.
  Unauthorized       : QueueError
  ||| The event payload could not be serialised or deserialised.
  SerializationError : QueueError

public export
Show QueueError where
  show ConnectionLost     = "ConnectionLost"
  show QueueNotFound      = "QueueNotFound"
  show MessageTooLarge    = "MessageTooLarge"
  show QuotaExceeded      = "QuotaExceeded"
  show AckTimeout         = "AckTimeout"
  show Unauthorized       = "Unauthorized"
  show SerializationError = "SerializationError"

||| Convert QueueError to C-compatible tag value.
public export
queueErrorToTag : QueueError -> Bits8
queueErrorToTag ConnectionLost     = 0
queueErrorToTag QueueNotFound      = 1
queueErrorToTag MessageTooLarge    = 2
queueErrorToTag QuotaExceeded      = 3
queueErrorToTag AckTimeout         = 4
queueErrorToTag Unauthorized       = 5
queueErrorToTag SerializationError = 6

---------------------------------------------------------------------------
-- Valid queue state transitions
---------------------------------------------------------------------------

||| Proof witness that a queue state transition is valid.
||| These mirror the proven-queueconn transition rules.
public export
data ValidQueueTransition : QueueState -> QueueState -> Type where
  ||| Disconnected -> Connected: initial connection established.
  Connect       : ValidQueueTransition Disconnected Connected
  ||| Connected -> Consuming: begin receiving events.
  StartConsuming : ValidQueueTransition Connected Consuming
  ||| Connected -> Producing: begin dispatching events.
  StartProducing : ValidQueueTransition Connected Producing
  ||| Consuming -> Connected: stop receiving, remain connected.
  StopConsuming  : ValidQueueTransition Consuming Connected
  ||| Producing -> Connected: stop dispatching, remain connected.
  StopProducing  : ValidQueueTransition Producing Connected
  ||| Connected -> Disconnected: graceful disconnect.
  Disconnect     : ValidQueueTransition Connected Disconnected
  ||| Any operational state -> Failed: connection error.
  ConnectedFail  : ValidQueueTransition Connected Failed
  ||| Consuming state -> Failed: error while receiving.
  ConsumingFail  : ValidQueueTransition Consuming Failed
  ||| Producing state -> Failed: error while dispatching.
  ProducingFail  : ValidQueueTransition Producing Failed
  ||| Failed -> Disconnected: reset after failure.
  ResetQueue     : ValidQueueTransition Failed Disconnected

---------------------------------------------------------------------------
-- HAR-specific constants
---------------------------------------------------------------------------

||| ABI version for HAR's proven-queueconn integration.
||| Increment when FFI signatures or tag values change.
public export
harQueueAbiVersion : Bits32
harQueueAbiVersion = 1

||| Maximum event payload size in bytes (1 MiB, matching proven-queueconn).
public export
maxEventSize : Nat
maxEventSize = 1048576

||| Default prefetch count for consuming events from upstream sources.
public export
defaultPrefetch : Nat
defaultPrefetch = 10

||| Default acknowledgement timeout in seconds for dispatched events.
public export
ackTimeout : Nat
ackTimeout = 30

||| Default delivery guarantee for rpa-elysium dispatch.
||| AtLeastOnce ensures no events are silently lost.
public export
rpaElysiumGuarantee : DeliveryGuarantee
rpaElysiumGuarantee = AtLeastOnce
