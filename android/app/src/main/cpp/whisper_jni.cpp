#include <jni.h>
#include <android/log.h>
#include <string>

#include "whisper.h"

#define TAG "WhisperJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

namespace {

struct ProgressCtx {
    JNIEnv *env;
    jobject listener;
    jmethodID method;
};

void on_progress(whisper_context *, whisper_state *, int progress, void *user_data) {
    auto *p = static_cast<ProgressCtx *>(user_data);
    if (p && p->listener && p->method) {
        p->env->CallVoidMethod(p->listener, p->method, static_cast<jint>(progress));
    }
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_mustafa_toolbox_WhisperLib_initContext(JNIEnv *env, jobject, jstring model_path) {
    const char *path = env->GetStringUTFChars(model_path, nullptr);
    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    whisper_context *ctx = whisper_init_from_file_with_params(path, cparams);
    LOGI("Loaded model %s -> %p", path, ctx);
    env->ReleaseStringUTFChars(model_path, path);
    return reinterpret_cast<jlong>(ctx);
}

extern "C" JNIEXPORT void JNICALL
Java_com_mustafa_toolbox_WhisperLib_freeContext(JNIEnv *, jobject, jlong ctx_ptr) {
    auto *ctx = reinterpret_cast<whisper_context *>(ctx_ptr);
    if (ctx) whisper_free(ctx);
}

// Returns UTF-8 bytes (decoded on the Kotlin side) or null on failure.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_mustafa_toolbox_WhisperLib_transcribe(JNIEnv *env, jobject, jlong ctx_ptr,
                                                   jfloatArray samples, jstring language,
                                                   jboolean translate, jint threads,
                                                   jobject listener) {
    auto *ctx = reinterpret_cast<whisper_context *>(ctx_ptr);
    if (!ctx) return nullptr;

    const char *lang = env->GetStringUTFChars(language, nullptr);

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = translate;
    params.language = lang;
    params.n_threads = threads;
    params.no_context = true;

    ProgressCtx pctx{env, listener, nullptr};
    if (listener) {
        jclass cls = env->GetObjectClass(listener);
        pctx.method = env->GetMethodID(cls, "onProgress", "(I)V");
        params.progress_callback = on_progress;
        params.progress_callback_user_data = &pctx;
    }

    jsize n = env->GetArrayLength(samples);
    jfloat *data = env->GetFloatArrayElements(samples, nullptr);
    int rc = whisper_full(ctx, params, data, n);
    env->ReleaseFloatArrayElements(samples, data, JNI_ABORT);
    env->ReleaseStringUTFChars(language, lang);

    if (rc != 0) return nullptr;

    std::string out;
    const int segments = whisper_full_n_segments(ctx);
    for (int i = 0; i < segments; ++i) {
        const char *text = whisper_full_get_segment_text(ctx, i);
        if (!text) continue;
        if (!out.empty()) out += ' ';
        out += text;
    }

    jbyteArray result = env->NewByteArray(static_cast<jsize>(out.size()));
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(out.size()),
                            reinterpret_cast<const jbyte *>(out.data()));
    return result;
}
