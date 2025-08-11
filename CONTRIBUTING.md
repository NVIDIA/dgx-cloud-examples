<!--
SPDX-FileCopyrightText: Copyright (c) 2025, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Contributing to DGX Cloud Examples

Thanks for your interest in contributing to DGX Cloud Examples!

Contributions fall into the following three categories.

1. To report a bug, request a new example, or report a problem with
    documentation, file an [issue](https://github.com/NVIDIA/dgx-cloud-examples/issues/new/choose)
    describing in detail the ssue. The team evaluates and triages issues regularly. 
    If you believe the issue needs priority attention, comment on the issue to notify the team.
2. To propose and implement a new example, file a new request
    [issue]((https://github.com/NVIDIA/dgx-cloud-examples/issues/new/choose). Describe the
    intended example and discuss the idea with the team and
    community. Once the team agrees that the plan is good, go ahead and
    implement it, using the [code contributions](#code-contributions) guide below.
3. To implement a example or bug-fix for an existing example, follow the 
    [code contributions](#code-contributions) guide below. If you
    need more context on a particular issue, ask in a comment.

As contributors and maintainers to this project, you are expected to abide by our code of conduct.
More information can be found at: [Contributor Code of Conduct](https://github.com/NVIDIA/dgx-cloud-examples/CODE_OF_CONDUCT.md).

## Code Contributions

### Your First Contribution

1. Fork this GitHub repo.
2. Create a branch for your new example or fixes. A suggested branch naming policy would be your GitHub username followed by the DGX Cloud product name, then
the example description. For example, ``roclark-nemo-new-llm-training-pipeline``.
3. Code! Ensure the [license headers are set properly](#licensing).
4. [Sign-off your commit](#signing-your-work).
4. When done, [create your pull request](https://github.com/NVIDIA/dgx-cloud-examples/compare).
5. Wait for other developers to review your code and update code as needed.
6. Once reviewed and approved, an Admin will merge your pull request.

Remember, if you are unsure about anything, don't hesitate to comment on issues and ask for clarifications!

## Licensing

DGX Cloud Examples is licensed under the Apache v2.0 license. All new source files should contain the Apache v2.0 license header. 
Any edits to existing source code should update the date range of the copyright to the current year. The format for the license header is:

```
/*
 * SPDX-FileCopyrightText: Copyright (c) <year>, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
 ```

## Signing Your Work

* We require that all contributors "sign-off" on their commits. This certifies that the contribution is your original work, or you have rights to submit it under the same license, or a compatible license.

  * Any contribution which contains commits that are not Signed-Off will not be accepted.

* To sign off on a commit you simply use the `--signoff` (or `-s`) option when committing your changes:
  ```bash
  $ git commit -s -m "Add cool feature."
  ```
  This will append the following to your commit message:
  ```
  Signed-off-by: Your Name <your@email.com>
  ```

* Full text of the DCO:

  ```
  Developer Certificate of Origin
  Version 1.1

  Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

  Everyone is permitted to copy and distribute verbatim copies of this
  license document, but changing it is not allowed.


  Developer's Certificate of Origin 1.1

  By making a contribution to this project, I certify that:

  (a) The contribution was created in whole or in part by me and I
      have the right to submit it under the open source license
      indicated in the file; or

  (b) The contribution is based upon previous work that, to the best
      of my knowledge, is covered under an appropriate open source
      license and I have the right under that license to submit that
      work with modifications, whether created in whole or in part
      by me, under the same open source license (unless I am
      permitted to submit under a different license), as indicated
      in the file; or

  (c) The contribution was provided directly to me by some other
      person who certified (a), (b) or (c) and I have not modified
      it.

  (d) I understand and agree that this project and the contribution
      are public and that a record of the contribution (including all
      personal information I submit with it, including my sign-off) is
      maintained indefinitely and may be redistributed consistent with
      this project or the open source license(s) involved.
  ```

## Attribution

Portions adopted from

* [https://github.com/nv-morpheus/Morpheus/blob/main/docs/source/developer_guide/contributing.md](https://github.com/nv-morpheus/Morpheus/blob/main/docs/source/developer_guide/contributing.md)
