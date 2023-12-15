/*
 * Copyright 2021 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#ifndef FIRESTORE_CORE_TEST_UNIT_TESTUTIL_BUNDLE_BUILDER_H_
#define FIRESTORE_CORE_TEST_UNIT_TESTUTIL_BUNDLE_BUILDER_H_

#include <string>

namespace firebase {
namespace firestore {
namespace testutil {

std::string CreateBundle(const std::string& project_id,
                         const std::string& database_id);

}  // namespace testutil
}  // namespace firestore
}  // namespace firebase

#endif  // FIRESTORE_CORE_TEST_UNIT_TESTUTIL_BUNDLE_BUILDER_H_
