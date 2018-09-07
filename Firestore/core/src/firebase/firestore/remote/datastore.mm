/*
 * Copyright 2018 Google
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

#include "Firestore/core/src/firebase/firestore/remote/datastore.h"

#include <unordered_set>

#include "Firestore/core/include/firebase/firestore/firestore_errors.h"
#include "Firestore/core/src/firebase/firestore/auth/token.h"
#include "Firestore/core/src/firebase/firestore/core/database_info.h"
#include "Firestore/core/src/firebase/firestore/remote/grpc_completion.h"
#include "Firestore/core/src/firebase/firestore/util/error_apple.h"
#include "Firestore/core/src/firebase/firestore/util/executor_libdispatch.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/log.h"
#include "Firestore/core/src/firebase/firestore/util/statusor.h"
#include "absl/memory/memory.h"
#include "absl/strings/str_cat.h"

namespace firebase {
namespace firestore {
namespace remote {

using auth::CredentialsProvider;
using auth::Token;
using core::DatabaseInfo;
using util::AsyncQueue;
using util::Status;
using util::StatusOr;
using util::internal::Executor;
using util::internal::ExecutorLibdispatch;

namespace {

std::unique_ptr<Executor> CreateExecutor() {
  auto queue = dispatch_queue_create("com.google.firebase.firestore.datastore",
                                     DISPATCH_QUEUE_SERIAL);
  return absl::make_unique<ExecutorLibdispatch>(queue);
}

std::string MakeString(grpc::string_ref grpc_str) {
  return {grpc_str.begin(), grpc_str.size()};
}

absl::string_view MakeStringView(grpc::string_ref grpc_str) {
  return {grpc_str.begin(), grpc_str.size()};
}

}  // namespace

Datastore::Datastore(const DatabaseInfo &database_info,
                     AsyncQueue *worker_queue,
                     CredentialsProvider* credentials,
                    FSTSerializerBeta *serializer)
    : grpc_connection_{database_info, worker_queue, &grpc_queue_},
      dedicated_executor_{CreateExecutor()},
serializer_bridge_{serializer} {
  dedicated_executor_->Execute([this] { PollGrpcQueue(); });
}

void Datastore::Shutdown() {
  for (auto& call : commit_calls_) {
    call->Cancel();
  }
  commit_calls_.clear();

  // `grpc::CompletionQueue::Next` will only return `false` once `Shutdown` has
  // been called and all submitted tags have been extracted. Without this call,
  // `dedicated_executor_` will never finish.
  grpc_queue_.Shutdown();
  // Drain the executor to make sure it extracted all the operations from gRPC
  // completion queue.
  dedicated_executor_->ExecuteBlocking([] {});
}

void Datastore::PollGrpcQueue() {
  HARD_ASSERT(dedicated_executor_->IsCurrentExecutor(),
              "PollGrpcQueue should only be called on the "
              "dedicated Datastore executor");

  void *tag = nullptr;
  bool ok = false;
  while (grpc_queue_.Next(&tag, &ok)) {
    auto completion = static_cast<GrpcCompletion *>(tag);
    HARD_ASSERT(tag, "gRPC queue returned a null tag");
    completion->Complete(ok);
  }
}

std::unique_ptr<GrpcStream> Datastore::CreateGrpcStream(
    absl::string_view rpc_name,
    absl::string_view token,
    GrpcStreamObserver *observer) {
  return grpc_connection_.CreateStream(token, rpc_name, observer);
}

void Datastore::CommitMutations(NSArray<FSTMutation *> *mutations,
                                FSTVoidErrorBlock completion) {
  grpc::ByteBuffer message = serializer_bridge_.ToByteBuffer(
      serializer_bridge_.CreateCommitRequest(mutations));

  credentials_->GetToken([this, message, completion](util::StatusOr<Token> maybe_token) {
    worker_queue_->EnqueueRelaxed([this, message, completion, maybe_token] () mutable {
      if (!maybe_token.ok()) {
        completion(util::MakeNSError(maybe_token.status()));
      }

      Token token = maybe_token.ValueOrDie();
      commit_calls_.push_back(grpc_connection_.CreateUnaryCall(
          token.user().is_authenticated() ? token.token() : "", "/google.firestore.v1beta1.Firestore/Commit", std::move(message)));
      auto call = commit_calls_.back().get();
      call->Start(
          [this, completion, call](const grpc::ByteBuffer & /*ignored_response*/,
                             const util::Status &status) {
            LOG_DEBUG("RPC CommitRequest completed. Error: %s: %s", status.code(), status.error_message());
            // LogHeadersForRpc(call_ptr->GetResponseHeaders(),
            // "CommitRequest");

            if (status.code() == FirestoreErrorCode::Unauthenticated) {
              credentials_->InvalidateToken();
            }

            completion(util::MakeNSError(status));

            auto found =
                std::find_if(commit_calls_.begin(), commit_calls_.end(),
                             [call](const std::unique_ptr<GrpcUnaryCall> &rhs) {
                               return call == rhs.get();
                             });
            HARD_ASSERT(found != commit_calls_.end(), "Missing GrpcUnaryCall");
            commit_calls_.erase(found);
          });
    });
  });
}

Status Datastore::ConvertStatus(grpc::Status from) {
    if (from.ok()) {
      return Status::OK();
    }

    grpc::StatusCode error_code = from.error_code();
    HARD_ASSERT(
        error_code >= grpc::CANCELLED && error_code <= grpc::UNAUTHENTICATED,
        "Unknown gRPC error code: %s", error_code);

    return {static_cast<FirestoreErrorCode>(error_code), from.error_message()};
}

std::string Datastore::GetWhitelistedHeadersAsString(
    const GrpcStream::MetadataT &headers) {
    static std::unordered_set<std::string> whitelist = {
        "date", "x-google-backends", "x-google-netmon-label",
        "x-google-service", "x-google-gfe-request-trace"};

    std::string result;
    for (const auto &kv : headers) {
      if (whitelist.find(MakeString(kv.first)) != whitelist.end()) {
        absl::StrAppend(&result, MakeStringView(kv.first), ": ",
                        MakeStringView(kv.second), "\n");
      }
    }
    return result;
}

}  // namespace remote
}  // namespace firestore
}  // namespace firebase
