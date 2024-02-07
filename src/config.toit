// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .api.config

service_/CellularConfigServiceClient? ::= (CellularConfigServiceClient).open
    --if_absent=: null

set-apn apn/string:
  service := service_
  if not service: throw "cellular unavailable"
  return service.set-apn apn

set-operator operator/string:
  service := service_
  if not service: throw "cellular unavailable"
  return service.set-operator operator

set-pin-code pin/string:
  service := service_
  if not service: throw "cellular unavailable"
  return service.set-pin-code pin
