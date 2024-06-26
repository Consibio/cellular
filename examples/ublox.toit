// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
This example demonstrates how to use the Monarch service and connect it to a
  cellular network.

To run this example using Jaguar, you'll first need to install the
  module service on the device.

$ jag pkg install --project-root examples/
$ jag container install ublox src/modules/ublox/sara_r5.toit
$ jag run examples/ublox.toit
*/

import http
import log
import net.cellular

main:
  config ::= {
    cellular.CONFIG_APN: "onomondo",

    cellular.CONFIG_UART_TX: 16,
    cellular.CONFIG_UART_RX: 17,
    cellular.CONFIG-POWER: [21, 1],
    cellular.CONFIG-RESET: [4, 1],

    cellular.CONFIG_LOG_LEVEL: log.DEBUG-LEVEL,
  }

  logger := log.default.with_name "ublox"
  logger.info "opening network"
  network := cellular.open config

  try:
    client := http.Client network
    host := "www.google.com"
    response := client.get host "/"

    bytes := 0
    elapsed := Duration.of:
      while data := response.body.read:
        bytes += data.size

    logger.info "http get" --tags={"host": host, "size": bytes, "elapsed": elapsed}

  finally:
    network.close
