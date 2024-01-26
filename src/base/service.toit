// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import gpio
import uart
import log

import net
import net.cellular

import encoding.tison
import system.assets
import system.containers

import system.services show ServiceHandler ServiceSelector ServiceProvider
import system.api.network show NetworkService
import system.api.cellular show CellularService
import system.base.network show ProxyingNetworkServiceProvider
import system.storage

import .cellular
import ..api.state
import ..state
import esp32

CELLULAR_FAILS_BETWEEN_RESETS /int ::= 8
CELLULAR_FAILS_UNTIL_SCAN  /int ::= 4
ACCEPTABLE_TIME_TO_ERROR /int ::= 300 // seconds = 5 minutes
OPERATOR_SCORE_THRESHOLD /int ::= 75

CELLULAR_RESET_NONE      /int ::= 0
CELLULAR_RESET_SOFT      /int ::= 1
CELLULAR_RESET_POWER_OFF /int ::= 2
CELLULAR_RESET_LABELS ::= ["none", "soft", "power-off"]

pin config/Map key/string -> gpio.Pin?:
  value := config.get key
  if not value: return null
  if value is int: return gpio.Pin value
  if value is not List or value.size != 2:
    throw "illegal pin configuration: $key == $value"

  pin := gpio.Pin value[0]
  mode := value[1]
  if mode != cellular.CONFIG_ACTIVE_HIGH: pin = gpio.InvertedPin pin
  pin.configure --output --open_drain=(mode == cellular.CONFIG_OPEN_DRAIN)
  pin.set 0  // Drive to in-active.
  return pin

abstract class CellularServiceProvider extends ProxyingNetworkServiceProvider:
  // We cellular service has been developed against known
  // versions of the network and cellular APIs. We keep a
  // copy of the versions here, so we will know if we the
  // version numbers in the core libraries change.
  static NETWORK_SELECTOR ::= ServiceSelector
      --uuid=NetworkService.SELECTOR.uuid
      --major=0
      --minor=4
  static CELLULAR_SELECTOR ::= ServiceSelector
      --uuid=CellularService.SELECTOR.uuid
      --major=0
      --minor=2

  // TODO(kasper): Let this be configurable.
  static SUSTAIN_FOR_DURATION_ ::= Duration --ms=100

  // TODO(kasper): Handle the configuration better.
  config_/Map? := null

  rx_/gpio.Pin? := null
  tx_/gpio.Pin? := null
  cts_/gpio.Pin? := null
  rts_/gpio.Pin? := null

  power_pin_/gpio.Pin? := null
  reset_pin_/gpio.Pin? := null

  driver_/Cellular? := null
  connected_at_/int? := null
  disconnected_at_/int? := null
  operator_/Operator? := null

  static ATTEMPTS_KEY ::= "attempts"
  static SIGNAL_QUAL_KEY ::= "signal.qual"
  static SIGNAL_POWER_KEY ::= "signal.pwr"
  static ICCID_KEY ::= "iccid"
  static MODEL_KEY ::= "model"
  static VERSION_KEY ::= "version"
  static SCORES_KEY ::= "operator.scores"
  bucket_/storage.Bucket ::= storage.Bucket.open --flash "toitware.com/cellular"
  attempts_/int := ?
  scores_/OperatorScores := ?

  constructor name/string --major/int --minor/int --patch/int=0:
    attempts/int? := null
    scores/Map? := null

    catch: attempts = bucket_.get ATTEMPTS_KEY
    catch: scores = bucket_.get SCORES_KEY

    attempts_ = attempts or 0
    scores_ = OperatorScores ((scores is Map) ? scores.copy : {:})

    super "system/network/cellular/$name" --major=major --minor=minor --patch=patch
    // The network starts closed, so we let the state of the cellular
    // container indicate that it is running in the background until
    // the network is opened.
    containers.notify-background-state-changed true
    provides NETWORK_SELECTOR
        --handler=this
        --priority=ServiceProvider.PRIORITY_UNPREFERRED
        --tags=["cellular"]
    provides CELLULAR_SELECTOR --handler=this
    provides CellularStateService.SELECTOR --handler=(CellularStateServiceHandler_ this)

  update_attempts_ value/int -> int:
    critical_do:
      catch: with_timeout --ms=10_000:
        bucket_[ATTEMPTS_KEY] = value
        attempts_ = value
    return value

  update_scores_:
    critical_do:
      catch: with_timeout --ms=10_000:
        bucket_[SCORES_KEY] = scores_.to_map

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == CellularService.CONNECT_INDEX:
      return connect client arguments
    return super index arguments --gid=gid --client=client

  abstract create_driver -> Cellular
      --logger/log.Logger
      --port/uart.Port
      --rx/gpio.Pin?
      --tx/gpio.Pin?
      --rts/gpio.Pin?
      --cts/gpio.Pin?
      --power/gpio.Pin?
      --reset/gpio.Pin?
      --baud_rates/List?

  connect client/int config/Map? -> List:
    if not config:
      config = {:}
      // TODO(kasper): It feels like the configurations present as assets
      // should form the basis (pins, etc.) and then additional options
      // provided by the client can give the rest as an overlay.
      assets.decode.get "cellular" --if_present=: | encoded |
        catch --trace: config = tison.decode encoded
      // TODO(kasper): Should we mix in configuration properties from
      // firmware.config?
    // TODO(kasper): This isn't a super elegant way of dealing with
    // the current configuration. Should we pass it through to $open_network
    // somehow instead?
    config_ = config
    return connect client

  proxy_mask -> int:
    return NetworkService.PROXY_RESOLVE | NetworkService.PROXY_UDP | NetworkService.PROXY_TCP

  open_network -> net.Interface:
    level := config_.get cellular.CONFIG_LOG_LEVEL --if_absent=: log.INFO_LEVEL
    logger := log.Logger level log.DefaultTarget --name="cellular"

    // Reset the selected operator
    operator_ = null

    driver/Cellular? := null
    catch: driver = open_driver logger
    // If we failed to create the driver, it may very well be
    // because we need to reset the modem. We give it one more
    // chance, so unless we're already past any deadline set up
    // by the caller of open, we'll get another shot at making
    // the modem communicate with us.
    if not driver: driver = open_driver logger

    apn := config_.get cellular.CONFIG_APN --if_absent=: ""
    bands := config_.get cellular.CONFIG_BANDS
    rats := config_.get cellular.CONFIG_RATS

    try:
      critical-do:
        // Get iccid, model and version and cache them
        catch: with-timeout --ms=5_000:
          update_cached_iccid driver.iccid
          update_cached_model driver.model
          update_cached_version driver.version

        // The CFUN command (called in both driver.configure where
        // the modem is disable with CFUN=0 and then enabled again
        // in driver.enable_radio) can take up to 3 minutes. However,
        // it ususally takes less than 1 seconds. We set the timeout
        // to 3 minutes to ensure that we don't stop the disabling
        // procedure prematurely, as we have observed that it can 
        // leave the modem in a bad state.
        print "enabling radio with timeout of 180_000 seconds..."
        with_timeout --ms=180_000:
          logger.info "configuring modem" --tags={"apn": apn}
          driver.configure apn --bands=bands --rats=rats
          logger.info "enabling radio"
          driver.enable_radio

        // Scans can take up to 3 minutes on u-blox SARA
        with_timeout --ms=180_000:
          catch --trace:

            // If we have tried to connect without succes more than
            // 32 times, reset the scores to ensure that we are not
            // stuck, if some scoring logic is broken.
            if (attempts_ > 0 and attempts_ % 32 == 0): 
              scores_.reset_all

            // Every other attempt, we rely on the modem's automatic
            // operator selection. This is to ensure that we try out
            // new operators properly before manually selecting a 
            // new one.
            if (attempts_ % 2 == 0):

              // If we have tried to connect without succes more than
              // the number of times defined by CELLULAR_FAILS_UNTIL_SCAN,
              // scan for operators on every 4th attempt.
              should_scan := (attempts_ > CELLULAR_FAILS_UNTIL_SCAN) and (attempts_ % 4 == 0)
              if (should_scan):
                logger.info "scanning for operators" --tags={"attempt": attempts_}
                scores_.set_available_operators driver.scan_for_operators

              // If the score of the operator connected last is below 
              // the OPERATOR_SCORE_THRESHOLD, manually connect to a 
              // new one, if there exists one with a higher score than 
              // the last. Also do this if we have just scanned for 
              // operators to ensure that we try out newly discovered
              // operators. 
              // If no known scores are known, score_for_last_operator 
              // will return 0, but get_best_operator will return null,
              // so it will attempt auto-COPS until a scan has been
              // performed at least one time.
              if scores_.score_for_last_operator < OPERATOR_SCORE_THRESHOLD or should_scan:
                operator_ = scores_.get_best_operator
                print "Using operator $operator_.op with score $(%.2f scores_.score_for_last_operator)%"

        // Connects can take up to 3 minutes on u-blox SARA
        with_timeout --ms=180_000:
          logger.info "connecting"
          driver.connect --operator=operator_
          
      update_attempts_ 0  // Success. Reset the attempts.
      logger.info "connected"

      // If we used auto-COPS (ie. operator_ is null), we poll
      // the modem for the operator it is connected to in order
      // to be able to provide it a score after the session. It is
      // more reliable to query the modem here after the shutdown
      // procedure is underway.
      /* if operator_ == null:
        catch:
          with_timeout --ms=5_000:
            operator_ = driver.get_connected_operator */

      connected_at_ = esp32.total_run_time
      // Once the network is established, we change the state of the
      // cellular container to indicate that it is now running in
      // the foreground and needs to have its proxied networks closed
      // correctly in order for the shutdown to be clean.
      containers.notify-background-state-changed false

      // Grab signal quality and cache it in the bucket.
      // In this way, it can be queried by a consumer of
      // the CellularStateService also when the connection
      // is down.
      signal := driver.signal_quality
      if signal:
        update_cached_signal_quality signal

      return driver.open-network --provider=this
    finally: | is_exception exception |
      if is_exception:
        critical_do: close_driver driver --error=exception.value
      else:
        driver_ = driver

  close_network network/net.Interface -> none:
    driver := driver_
    driver_ = null
    logger := driver.logger
    critical_do:
      try:
        close_driver driver
      finally:
        // After closing the network, we change the state of the cellular
        // container to indicate that it is now running in the background.
        containers.notify-background-state-changed true

  open_driver logger/log.Logger -> Cellular:
    attempts := update_attempts_ attempts_ + 1
    attempts_since_reset ::= attempts % CELLULAR_FAILS_BETWEEN_RESETS
    attempts_until_reset ::= attempts_since_reset > 0
        ? (CELLULAR_FAILS_BETWEEN_RESETS - attempts_since_reset)
        : 0

    reset := CELLULAR_RESET_NONE
    if attempts_until_reset == 0:
      power_off ::= attempts % (CELLULAR_FAILS_BETWEEN_RESETS * 2) == 0
      reset = power_off ? CELLULAR_RESET_POWER_OFF : CELLULAR_RESET_SOFT
      if attempts >= 65536: attempts = update_attempts_ 0

    logger.info "initializing modem" --tags={
      "attempt": attempts,
      "reset": CELLULAR_RESET_LABELS[reset],
    }

    uart_baud_rates/List? := config_.get cellular.CONFIG_UART_BAUD_RATE
        --if_present=: it is List ? it : [it]
    uart_high_priority/bool := config_.get cellular.CONFIG_UART_PRIORITY
        --if_present=: it == cellular.CONFIG_PRIORITY_HIGH
        --if_absent=: false

    tx_  = pin config_ cellular.CONFIG_UART_TX
    rx_  = pin config_ cellular.CONFIG_UART_RX
    cts_ = pin config_ cellular.CONFIG_UART_CTS
    rts_ = pin config_ cellular.CONFIG_UART_RTS

    power_pin_ = pin config_ cellular.CONFIG_POWER
    reset_pin_ = pin config_ cellular.CONFIG_RESET

    port := uart.Port
        --baud_rate=Cellular.DEFAULT_BAUD_RATE
        --high_priority=uart_high_priority
        --tx=tx_
        --rx=rx_
        --cts=cts_
        --rts=rts_

    driver := create_driver
        --logger=logger
        --port=port
        --rx=rx_
        --tx=tx_
        --rts=rts_
        --cts=cts_
        --power=power_pin_
        --reset=reset_pin_
        --baud_rates=uart_baud_rates

    try:
      if reset == CELLULAR_RESET_SOFT:
        driver.reset
        sleep --ms=1_000
      else if reset == CELLULAR_RESET_POWER_OFF:
        driver.power_off
        sleep --ms=1_000
      with_timeout --ms=20_000: driver.wait_for_ready
      return driver
    finally: | is_exception _ |
      if is_exception:
        // Turning the cellular modem on failed, so we artificially
        // bump the number of attempts to get close to a reset.
        if attempts_until_reset > 1:
          update_attempts_ attempts + attempts_until_reset - 1
        // Close the UART before closing the pins. This is typically
        // taken care of by a call to driver.close, but in this case
        // we failed to produce a working driver instance.
        port.close
        close_pins_

  close_driver driver/Cellular --error/any=null -> none:
    logger := driver.logger
    log_level := error ? log.WARN_LEVEL : log.INFO_LEVEL
    log_tags := error ? { "error": error } : null
    try:
      catch --trace: with-timeout --ms=10_000:
        disconnected_at_ = esp32.total_run_time
        log.log log_level "closing" --tags=log_tags
        
        // Calculate time_to_error as the number of seconds from the
        // connected_at_ time to the disconnected_at_ time (which are
        // both in microseconds, so we converted to secs and round).
        // If the modem was never connected, we set time_to_error to
        // 0 seconds.
        time_to_error := (connected_at_ is int) ?  ((disconnected_at_ - connected_at_)*0.000001).round : 0

        // Calculate the tte_score (time-to-error score). If the
        // driver was closed with an error, we use the time_to_error
        // as the tte_score. Otherwise, we use the ACCEPTABLE_TIME_TO_ERROR
        // as the tte_score. This is to ensure that we don't penalize
        // the operator for a connection that was closed cleanly.
        tte_score := (error) ? time_to_error : ACCEPTABLE_TIME_TO_ERROR

        // Get the currently active operator in order to score it properly.
        // If operator_ was defined during connection, use that. Otherwise,
        // we try to query the modem for the currently connected operator.
        // If that fails, we assume that the operator is the same as the last
        // (which is almost always the case) and pull it from the last session
        // in the scores_.
        operator := operator_
        /* if not operator:
          catch:
            with-timeout --ms=5_000: 
              operator = driver.get_connected_operator */
        if not operator:
          operator = scores_.get_last_operator

        // If we have an operator, we score it.
        if operator:
          scores_.add --tte=tte_score --time=Time.now --operator=operator
          update_scores_
          logger.info "Saved new operator score to flash for $operator.op. Scores are now: $scores_.stringify_scores"

      // Close the driver
      catch: with_timeout --ms=20_000: driver.close
      if rts_:
        rts_.configure --output
        rts_.set 0

      // It appears as if we have to wait for RX to settle down, before
      // we start to look at the power state.
      catch: with_timeout --ms=10_000: wait_for_quiescent_ rx_

      // The call to driver.close sends AT+CPWROFF. If the session wasn't
      // active, this can fail and therefore we probe its power state and
      // force it to power down if needed. The routine is not implemented
      // for all modems, in which case is_power_off will return null.
      // Therefore, we explicitly check for false.
      is_powered_off := driver.is_powered_off
      if is_powered_off == false:
        logger.info "power off not complete, forcing power down"
        driver.power_off
      else if is_powered_off == null:
        logger.info "cannot determine power state, assuming it's correctly powered down"
      else:
        logger.info "module is correctly powered off"

    finally:
      close_pins_
      log.log log_level "closed" --tags=log_tags

  close_pins_ -> none:
    if tx_: tx_.close
    if rx_: rx_.close
    if cts_: cts_.close
    if rts_: rts_.close
    if power_pin_: power_pin_.close
    if reset_pin_: reset_pin_.close
    tx_ = rx_ = cts_ = rts_ = power_pin_ = reset_pin_ = null

  // Block until a value has been sustained for at least $SUSTAIN_FOR_DURATION_.
  static wait_for_quiescent_ pin/gpio.Pin:
    pin.configure --input
    while true:
      value := pin.get

      // See if value is sustained for the required amount.
      e := catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout SUSTAIN_FOR_DURATION_:
          pin.wait_for 1 - value

      // If we timed out, we're done.
      if e: return

      // Sleep for a little while. This allows us to take any
      // deadlines into consideration.
      sleep --ms=10

  get_cached_signal_quality -> SignalQuality?:
    quality := bucket_.get SIGNAL_QUAL_KEY
    power := bucket_.get SIGNAL_POWER_KEY
    return (quality and power) ? (SignalQuality --power=power --quality=quality) : null
  
  update_cached_signal_quality signal_quality/SignalQuality:
    bucket_[SIGNAL_QUAL_KEY] = signal_quality.quality
    bucket_[SIGNAL_POWER_KEY] = signal_quality.power

  get_cached_iccid -> string?:
    iccid := bucket_.get ICCID_KEY
    return iccid ? iccid : null
  
  update_cached_iccid iccid/string:
    bucket_[ICCID_KEY] = iccid

  get_cached_model -> string?:
    model := bucket_.get MODEL_KEY
    return model ? model : null

  update_cached_model model/string:
    bucket_[MODEL_KEY] = model

  get_cached_version -> string?:
    version := bucket_.get VERSION_KEY
    return version ? version : null

  update_cached_version version/string:
    bucket_[VERSION_KEY] = version


class CellularStateServiceHandler_ implements ServiceHandler CellularStateService:
  provider/CellularServiceProvider
  constructor .provider:

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == CellularStateService.QUALITY_INDEX: return quality arguments
    if index == CellularStateService.ICCID_INDEX: return iccid
    if index == CellularStateService.MODEL_INDEX: return model
    if index == CellularStateService.VERSION_INDEX: return version
    unreachable

  quality cache/bool=true -> any:
    result := null
    catch: result = provider.get_cached_signal_quality
    return result ? [ result.power, result.quality ] : null

  iccid -> string?:
    catch: return provider.get_cached_iccid
    return null

  model -> string?:
    catch: return provider.get_cached_model
    return null

  version -> string?:
    catch: return provider.get_cached_version
    return null


class OperatorScores:
  static RESET-SCORE ::= OPERATOR_SCORE_THRESHOLD + 1.0
  operator_scores_/Map? := null

  constructor operator_scores/Map?:
    operator_scores_ = operator_scores or {:}

  add --tte/int --time/Time --operator/Operator -> float?:
    last_operator_session := operator_scores_.get operator.op --if-absent=: {:}
    if last_operator_session is not Map: last_operator_session = {:}
    last_score := last_operator_session.get "score" --if_absent=: RESET-SCORE
    tte = (tte > ACCEPTABLE_TIME_TO_ERROR) ? ACCEPTABLE_TIME_TO_ERROR : tte
    new_score := (0.2*(tte/ACCEPTABLE-TIME-TO-ERROR)*100.0 + 0.8*last_score)
    operator_scores_[operator.op] = {"tte": tte, "time": time.s-since-epoch, "score": new_score, "available": true}
    return new_score

  reset_all:
    operator_scores_ = {:}

  reset_scores:
    operator_scores_.do: | op session |
      session["score"] = RESET-SCORE

  operators -> List:
    return operator_scores_.keys

  stringify_scores -> string:
    strings := []
    operator_scores_.do: | op session |
      score := session.get "score"
      strings.add "($op: $(score is float ? "$(%.2f score)%" : "-"))"
    return strings.join ", "

  set_available_operators operators/List -> none:
    operators_to_remove := []
    operators_codes := operators.map: | operator | operator.op
    operator_scores_.do: | op |
      if not operators_codes.contains op: operators_to_remove.add op
    operators_to_remove.do: | op |
      operator_scores_[op]["available"] = false

    operators_codes.do: | op |
      if not operator_scores_.contains op: operator_scores_[op] = {"available": true}

    // If more than X operators are in the map, remove the oldest one that's not available
    if operators.size > 32:
      oldest_unavailable := null
      oldest_unavailable_time := 0
      operator_scores_.do: | op session |
        if not (session.get "available" --if_absent=: true):
          session_time := session.get "time" --if_absent=: 0
          if session_time > oldest_unavailable_time:
            oldest_unavailable_time = session_time
            oldest_unavailable = op
      if oldest_unavailable: 
        operator_scores_.remove oldest_unavailable

  get_best_operator -> Operator?:
    best_op := null
    best_score := 0
    operator_scores_.do: | op session |
      available := (session is Map) ? (session.get "available" --if_absent=: true) : true
      if available:
        score := (session is Map) ? (session.get "score" --if_absent=: RESET-SCORE) : RESET-SCORE
        if score > best_score:
          best_score = score
          best_op = op

    return (best_op is string and best_op.size > 0) ? (Operator best_op) : null

  to_map -> Map:
    return operator_scores_

  get_last_session_ -> Map?:
    if not operator_scores_: return null
    last_session := null
    last_session_time := 0
    operator_scores_.do: | op session |
      if session is Map:
        session_time := session.get "time" --if_absent=: 0
        if session_time > last_session_time:
          last_session_time = session_time
          last_session = session
    return last_session

  get_last_operator -> Operator?:
    if not operator_scores_ is Map: return null
    last_session_time := 0
    last_op := null
    operator_scores_.do: | op session |
      if session is Map:
        session_time := session.get "time" --if_absent=: 0
        if session_time > last_session_time:
          last_session_time = session_time
          last_op = op
    return (last_op is string and last_op.size > 0) ? (Operator last_op) : null

  score_for_last_operator -> float:
    session := get_last_session_

    // If there is no last session, return 0 to indicate that 
    // we should scan for operators.
    if not session: return 0.0

    // If there is a sessions but it doesn't have a score yet,
    // return the RESET-SCORE.
    return (session.get "score" --if_absent=: RESET-SCORE).to_float
