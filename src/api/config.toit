// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services
import ..state show SignalQuality

interface CellularConfigService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="3f1b5a45-fe4b-4141-b087-66cc33993942"
      --major=0
      --minor=1

  set-apn apn/string
  static APN_INDEX ::= 0

  set-pin-code pin/string
  static PIN_INDEX ::= 1

class CellularConfigServiceClient extends services.ServiceClient implements CellularConfigService:
  static SELECTOR ::= CellularConfigService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  set-apn apn/string:
    return invoke_ CellularConfigService.APN_INDEX null

  set-pin-code pin/string:
    return invoke_ CellularConfigService.PIN_INDEX null
