static Result<void> do_nns_prepare_backing(const BuiltinArguments&) {
    if (nns_prepare_backing([](const char* path, mode_t mode) {
            return make_dir(path, mode) ? 0 : -1;
        }) < 0) {
        return ErrnoError() << "NNS backing preparation failed";
    }
    return {};
}
