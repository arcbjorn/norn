# Third-party notices

Norn is MIT licensed; see [LICENSE](LICENSE). It links the components below,
two of which require attribution in distributed binaries. Nothing here is
copyleft, so static linking carries no source obligation.

This file must ship with any binary release.

## Odin

Zlib. <https://github.com/odin-lang/Odin>

Copyright (c) 2016-2025 Ginger Bill. All rights reserved.

This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use
of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it freely,
subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software. If you use this software in a product,
   an acknowledgment in the product documentation would be appreciated but is
   not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

## wgpu-native

Apache-2.0 OR MIT, used under Apache-2.0.
<https://github.com/gfx-rs/wgpu-native>

Copyright the gfx-rs authors.

Licensed under the Apache License, Version 2.0. You may obtain a copy at
<http://www.apache.org/licenses/LICENSE-2.0>. Unless required by applicable law
or agreed to in writing, software distributed under the License is distributed
on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
express or implied.

The pinned version is recorded in
[docs/13-engineering-notes.md](docs/13-engineering-notes.md); a release must
match the `BINDINGS_VERSION` of the Odin release it was built with.

## SDL3

Zlib. <https://github.com/libsdl-org/SDL>

Copyright (C) 1997-2026 Sam Lantinga and contributors.

This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use
of this software. Permission is granted to anyone to use this software for any
purpose, including commercial applications, and to alter it and redistribute
it freely, subject to the restrictions in the Zlib license.

Attribution is not required by the license. It is here because the project
depends on it.

## stb_truetype

MIT OR Unlicense (public domain). <https://github.com/nothings/stb>

Copyright (c) 2017 Sean Barrett.

No obligation under either option. Included for completeness.

## Fonts

No font is bundled. Norn reads system faces at runtime — on macOS from
`/System/Library/Fonts`, which is not redistributable. A release that bundles a
face must add its license here, and Linux support will need either a bundled
open face or per-platform discovery.
