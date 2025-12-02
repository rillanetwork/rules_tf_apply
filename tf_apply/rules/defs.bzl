"""
Starlark rules for initializing, planning, and applying Terraform modules using Bazel.
"""

load("@rules_tf//tf/rules:providers.bzl", "TfModuleInfo")

def relative_path(path, other_path):
    """
    Returns the relative path from `other_path` to `path`, given both paths have the same root.

    Args:
        path: The target path
        other_path: The base path

    Returns:
        The relative path from `other_path` to `path`.
    """

    path_parts = path.split("/")
    other_path_parts = other_path.split("/")

    # Find common prefix
    common_length = 0
    for p1, p2 in zip(path_parts, other_path_parts):
        if p1 == p2:
            common_length += 1
        else:
            break

    # Calculate the relative path
    relative_parts = [".."] * (len(other_path_parts) - common_length) + path_parts[common_length:]
    return "/".join(relative_parts)

def tf_vars_impl(ctx):
    """
    Generates a tfvars file from the provided key-value pairs.

    Args:
        ctx: The rule context

    Returns:
        DefaultInfo with the generated tfvars file.
    """
    tfvars_file = ctx.actions.declare_file("{}.bazel.auto.tfvars".format(ctx.attr.name_prefix))

    tfvar_deps = []
    tfvars = dict(ctx.attr.tfvars)

    for key, target in ctx.attr.tfvars_deps.items():
        tfvar_deps.extend(target.files.to_list())

        rel_path = relative_path(target.files.to_list()[0].short_path, ctx.attr.module.label.package)
        tfvars[key] = rel_path

    ctx.actions.write(
        output = tfvars_file,
        content = "\n".join(['{}="{}"'.format(key, value) for key, value in tfvars.items()]) + "\n",
    )

    return [DefaultInfo(files = depset([tfvars_file], transitive = [depset(tfvar_deps)]))]

tf_vars = rule(
    implementation = tf_vars_impl,
    attrs = {
        "name_prefix": attr.string(),
        "tfvars_deps": attr.string_keyed_label_dict(
            default = {},
            doc = "Mapping of tfvars to labels containing the files.",
        ),
        "module": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The Tf module to apply.",
        ),
        "tfvars": attr.string_dict(
            default = {},
            doc = "Mapping of tfvars to string values.",
        ),
    },
    # outputs = {"tfvars": "bazel.tfvars"},
    doc = """
    Generates a tfvars file from the provided key-value pairs.
    """,
)

def tf_backend_impl(ctx):
    """
    Defines the backend configuration for a Terraform root module.

    Args:
        ctx: The rule context

    Returns:
        An empty list as this rule does not produce any outputs.
    """

    backend_file = ctx.actions.declare_file("{}.bazel.backend.tf".format(ctx.attr.name_prefix))
    backend_content = 'terraform {{\n  backend "{}" {{\n'.format(ctx.attr.type)
    for key, value in ctx.attr.config.items():
        backend_content += '    {} = "{}"\n'.format(key, value)
    backend_content += "  }\n}\n"

    ctx.actions.write(
        output = backend_file,
        content = backend_content,
    )

    return [DefaultInfo(files = depset([backend_file], transitive = []))]

tf_backend = rule(
    implementation = tf_backend_impl,
    attrs = {
        "name_prefix": attr.string(),
        "type": attr.string(
            mandatory = True,
            doc = "The backend type.",
        ),
        "config": attr.string_dict(
            default = {},
            doc = "The backend configuration.",
        ),
    },
    doc = """
    Defines the backend configuration for a Terraform root module.
    """,
)

def tf_init_impl(ctx):
    """
    Builds a script to run tf init for the specified module.

    Args:
        ctx: The rule context

    Returns:
        An executable DefaultInfo object with the output init script.
    """

    tf_toolchain = ctx.toolchains["@rules_tf//:tf_toolchain_type"]

    init_script = ctx.actions.declare_file(ctx.label.name)

    ctx.actions.expand_template(
        output = init_script,
        template = ctx.file._script_template,
        substitutions = {
            "%TF_BIN_PATH%": tf_toolchain.runtime.tf.short_path,
            "%TF_DIR%": ctx.attr.module.label.package,
            "%TF_PLUGINS_DIR%": tf_toolchain.runtime.mirror.short_path,
        },
    )

    tfvars_deps = (ctx.attr.tfvars[DefaultInfo].files.to_list() if ctx.attr.tfvars else [])
    backend_deps = (ctx.attr.backend[DefaultInfo].files.to_list() if ctx.attr.backend else [])

    # find file ending with tfvars
    tfvars_file = [file for file in tfvars_deps if file.short_path.endswith(".tfvars")][0]

    deps = ctx.attr.module[TfModuleInfo].transitive_srcs.to_list() + tf_toolchain.runtime.deps + tfvars_deps + backend_deps

    return [DefaultInfo(
        executable = init_script,
        runfiles = ctx.runfiles(files = deps, symlinks = {
            ctx.attr.module.label.package + "/bazel.auto.tfvars": tfvars_file,
            ctx.attr.module.label.package + "/bazel.backend.tf": backend_deps[0] if backend_deps else None,
        }),
    )]

tf_init = rule(
    implementation = tf_init_impl,
    executable = True,
    attrs = {
        "module": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The Tf module to apply.",
        ),
        "tfvars": attr.label(
            doc = "The tfvars target to use for the module.",
        ),
        "backend": attr.label(
            doc = "The backend target to use for the module.",
        ),
        "_script_template": attr.label(
            default = Label(":tf_init.sh"),
            allow_single_file = True,
            # executable = True,
            doc = "Script to run for applying the Tf module.",
        ),
    },
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)

def tf_plan_impl(ctx):
    """
    Builds a script to run tf plan for the specified module.

    Args:
        ctx: The rule context

    Returns:
        An executable DefaultInfo object with the output plan script.
    """

    tf_toolchain = ctx.toolchains["@rules_tf//:tf_toolchain_type"]

    plan_script = ctx.actions.declare_file(ctx.label.name)

    ctx.actions.expand_template(
        output = plan_script,
        template = ctx.file._script_template,
        substitutions = {
            "%TF_BIN_PATH%": tf_toolchain.runtime.tf.short_path,
            "%TF_DIR%": ctx.attr.module.label.package,
            "%TF_PLUGINS_DIR%": tf_toolchain.runtime.mirror.short_path,
        },
    )

    tfvars_deps = (ctx.attr.tfvars[DefaultInfo].files.to_list() if ctx.attr.tfvars else [])
    backend_deps = (ctx.attr.backend[DefaultInfo].files.to_list() if ctx.attr.backend else [])

    # find file ending with tfvars
    tfvars_file = [file for file in tfvars_deps if file.short_path.endswith(".tfvars")][0]

    # Run the init script
    deps = ctx.attr.module[TfModuleInfo].transitive_srcs.to_list() + tf_toolchain.runtime.deps + tfvars_deps + backend_deps

    return [DefaultInfo(
        executable = plan_script,
        runfiles = ctx.runfiles(files = deps, symlinks = {
            ctx.attr.module.label.package + "/bazel.auto.tfvars": tfvars_file,
            ctx.attr.module.label.package + "/bazel.backend.tf": backend_deps[0] if backend_deps else None,
        }),
    )]

tf_plan = rule(
    implementation = tf_plan_impl,
    executable = True,
    attrs = {
        "module": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The Tf module to apply.",
        ),
        "tfvars": attr.label(
            doc = "The tfvars target to use for the module.",
        ),
        "backend": attr.label(
            doc = "The backend target to use for the module.",
        ),
        "_script_template": attr.label(
            default = Label(":tf_plan.sh"),
            allow_single_file = True,
            # executable = True,
            doc = "Script to run for applying the Tf module.",
        ),
    },
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)

def tf_apply_impl(ctx):
    """
    Builds a script to run tf apply for the specified module.

    Args:
        ctx: The rule context

    Returns:
        An executable DefaultInfo object with the output apply script.
    """

    tf_toolchain = ctx.toolchains["@rules_tf//:tf_toolchain_type"]

    apply_script = ctx.actions.declare_file(ctx.label.name)

    ctx.actions.expand_template(
        output = apply_script,
        template = ctx.file._script_template,
        substitutions = {
            "%TF_BIN_PATH%": tf_toolchain.runtime.tf.short_path,
            "%TF_DIR%": ctx.attr.module.label.package,
            "%TF_PLUGINS_DIR%": tf_toolchain.runtime.mirror.short_path,
        },
    )

    tfvars_deps = (ctx.attr.tfvars[DefaultInfo].files.to_list() if ctx.attr.tfvars else [])
    backend_deps = (ctx.attr.backend[DefaultInfo].files.to_list() if ctx.attr.backend else [])

    # find file ending with tfvars
    tfvars_file = [file for file in tfvars_deps if file.short_path.endswith(".tfvars")][0]

    deps = ctx.attr.module[TfModuleInfo].transitive_srcs.to_list() + tf_toolchain.runtime.deps + tfvars_deps + backend_deps

    return [DefaultInfo(
        executable = apply_script,
        runfiles = ctx.runfiles(files = deps, symlinks = {
            ctx.attr.module.label.package + "/bazel.auto.tfvars": tfvars_file,
            ctx.attr.module.label.package + "/bazel.backend.tf": backend_deps[0] if backend_deps else None,
        }),
    )]

tf_apply = rule(
    implementation = tf_apply_impl,
    executable = True,
    attrs = {
        "module": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The Tf module to apply.",
        ),
        "tfvars": attr.label(
            doc = "The tfvars target to use for the module.",
        ),
        "backend": attr.label(
            doc = "The backend target to use for the module.",
        ),
        "_script_template": attr.label(
            default = Label(":tf_apply.sh"),
            allow_single_file = True,
            # executable = True,
            doc = "Script to run for applying the Tf module.",
        ),
    },
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)
