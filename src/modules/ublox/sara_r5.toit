// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import gpio
import log
import uart

import .ublox

import ...base.at as at
import ...base.base as cellular
import ...base.cellular as cellular
import ...base.service show CellularServiceProvider

main:
  service := SaraR5Service
  service.install

// --------------------------------------------------------------------------

class SaraR5Service extends CellularServiceProvider:
  constructor:
    super "ublox/sara_r5" --major=0 --minor=1 --patch=0

  create_driver -> cellular.Cellular
      --logger/log.Logger
      --port/uart.Port
      --rx/gpio.Pin?
      --tx/gpio.Pin?
      --rts/gpio.Pin?
      --cts/gpio.Pin?
      --power/gpio.Pin?
      --reset/gpio.Pin?
      --baud_rates/List?:
    return SaraR5 port logger
        --rx=rx
        --tx=tx
        --rts=rts
        --cts=cts
        --pwr_on=power
        --reset_n=reset
        --uart_baud_rates=baud_rates or [460_800, cellular.Cellular.DEFAULT_BAUD_RATE]
        --is_always_online=true

/**
Driver for Sara-R5, GSM communicating over NB-IoT & M1.
*/
class SaraR5 extends UBloxCellular:
  static CONFIG_ ::= {:}

  rx/gpio.Pin?
  tx/gpio.Pin?
  rts/gpio.Pin?
  cts/gpio.Pin?
  pwr_on/gpio.Pin?
  reset_n/gpio.Pin?

  constructor port/uart.Port logger/log.Logger
      --.rx=null
      --.tx=null
      --.rts=null
      --.cts=null
      --.pwr_on=null
      --.reset_n=null
      --uart_baud_rates/List
      --is_always_online/bool:
    super
      port
      --logger=logger
      --config=CONFIG_
      --cat_m1
      --uart_baud_rates=uart_baud_rates
      --use_psm=not is_always_online

  network_name -> string:
    return "cellular:sara-r5"

  static list_equals_ a/List b/List -> bool:
    if a.size != b.size: return false
    a.size.repeat:
      if a[it] != b[it]: return false
    return true

  on_connected_ session/at.Session:
    upsd_status := session.set "+UPSND" [0, 8] --timeout=(Duration --s=5)
    if list_equals_ upsd_status.last [0, 8, 1]:
      // The PDP profile is already active. Trying to change it is
      // an illegal operation at this point.
      return
 
    // Set DNS servers to one of Google's DNS servers.
    // If left untouched, the network will normally provide it,
    // but we have seen that the this can be unreliable for some
    // networks (e.g. Telenor DK and TDC DK)
    if not registered_on_network_: throw "not registered on network"
    session.set "+UPSD" [0, 4, "8.8.8.8"] --timeout=(Duration --s=5)
    session.set "+UPSD" [0, 5, "8.8.4.4"] --timeout=(Duration --s=5)

    // Activate PDP context 1.
    if not registered_on_network_: throw "not registered on network"
    session.set "+CGACT" [1, 1] --timeout=(Duration --s=150)

    //TODO: Handle handling of IP protocol type depending on 
    // product version. From the Internet Applications dev guide:
    // For SARA-R5 "00B" product version, what matters is the 
    // protocol type set when issuing the +CGDCONT set command, 
    // and not what is provided as the response of the +CGDCONT 
    // read command, which could be different. In the opposite 
    // manner, for SARA-R5 "01B" product version and onwards, 
    // the internal PSD profile must set a protocol type exactly 
    // as read in the +CGDCONT AT command after registration 
    // to the network.

    // Set the protocol type to IPv4.
    // Possible options are:
    //    0 (default value): IPv4
    //    1: IPv6
    //    2: IPv4v6 with IPv4 preferred for internal sockets
    //    3: IPv4v6 with IPv6 preferred for internal sockets
    if not registered_on_network_: throw "not registered on network"
    session.set "+UPSD" [0, 0, 0] --timeout=(Duration --s=5)

    // Map PSD profile id 0 to PDP context ID (cid) 1
    if not registered_on_network_: throw "not registered on network"
    session.set "+UPSD" [0, 100, 1] --timeout=(Duration --s=5)

    // Activate the PSD profile #0.
    // This should be called each time. If not called
    // the subsequent USOCR (socket create) will fail.
    if not registered_on_network_: throw "not registered on network"
    send_abortable_ session (UPSDA --action=3)

  psm_enabled_psv_target -> List:
    return [1, 2000]  // TODO(kasper): Testing - go to sleep after ~9.2s.

  reboot_after_cedrxs_or_cpsms_changes -> bool:
    return false

  on_reset session/at.Session:
    session.send
      cellular.CFUN.reset --reset_sim

  power_on -> none:
    if not pwr_on: return
    // The datasheet states that RESET_N must be pulled low for
    // min. 1sec and max. 2sec to initiate a power on sequence.
    // We do this by setting PWR_ON high (the line is inverted
    // on most boards), then waiting for 1.5s
    critical_do --no-respect_deadline:
      logger.debug "performing power_on sequence for Sara-R5"
      pwr_on.set 1
      sleep --ms=1500
      pwr_on.set 0
      // The module is ready approx. 2sec after the power on
      // sequence is initiated. We wait a little while here 
      // to force the consumer of this method to wait 
      // appropriately.
      sleep --ms=500

  power_off -> none:
    if not (pwr_on and reset_n): return
    critical_do --no-respect_deadline:
      pwr_on.set 1
      reset_n.set 1
      sleep --ms=23_100  // Minimum is 23,000 ms.
      pwr_on.set 0
      sleep --ms=1_600   // Minimum is 1,500 ms.
      reset_n.set 0

  reset -> none:
    if not reset_n: return
    critical_do --no-respect_deadline:
      reset_n.set 1
      sleep --ms=150  // Minimum is 100ms.
      reset_n.set 0
      sleep --ms=250  // Wait like we do in $power_on.

  is_powered_off -> bool?:
    if rx == null: return null

    // On SARA-R5, the RXD pin (modem's uart output) is a push-pull
    // pin which is idle high and active low. When the modem is
    // powered up, this pin will be connected to the internal 1.8V
    // rail, which is turned off during power down. Therefore, by
    // momentarily configuring the pin with a pull-down on the host
    // microcontroller, we can assess the modem's state by checking
    // this pin - without waking the modem up again. If the modem is
    // powered up, RX will be high, and if it's powered down, it will
    // be low (ensured by the pull-down).

    rx.configure --input --pull-down

    // Run multiple checks of the pin state to ensure that it's not flickering.
    all_low := true
    8.repeat:
      if all_low and rx.get == 1: all_low = false

    // Reconfigure the RX pin as normal input.
    rx.configure --input
    return all_low

  get_connected_operator -> cellular.Operator?:
    catch --trace:
      at_.do: | session/at.Session |
        // Extract MCC and MNC from the UCGED response.
        // This command is independent of COPS operator format settings
        // so we use this one on SARA-R5
        description := (session.read "+UCGED").responses
        if description.size >= 2:
          network_desc := description[1]
          if network_desc.size >= 3:
            mcc := network_desc[2]
            mnc := network_desc[3]
            if mcc and mnc:
              return cellular.Operator "$(mcc)$(mnc)"

    return null


class UPSDA extends at.Command:
  // UPSDA times out after 180s, but since it can be aborted, any timeout can be used.
  static MAX_TIMEOUT ::= Duration --m=3

  constructor --action/int:
    super.set "+UPSDA" --parameters=[0, action] --timeout=compute_timeout

  // We use the deadline in the task to let the AT processor know that we can abort
  // the UPSDA operation by sending more AT commands.
  static compute_timeout -> Duration:
    return min MAX_TIMEOUT (Duration --us=(Task.current.deadline - Time.monotonic_us))
