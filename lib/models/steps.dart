// fix381: the per-step enum was 8 values (welcome, sourceType, name,
// url, username, password, epgUrl, finish). The Add Source flow
// collapsed to a single form page, so the enum is now 4 values.
enum Steps { welcome, sourceType, form, finish }
