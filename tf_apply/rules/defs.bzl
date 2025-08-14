"""
Starlark rules for initializing, planning, and applying Terraform modules using Bazel.
"""

load("@rules_tf//tf/rules:providers.bzl", "TfModuleInfo")

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

    # Run the init script
    deps = ctx.attr.module[TfModuleInfo].transitive_srcs.to_list() + tf_toolchain.runtime.deps

    return [DefaultInfo(
        executable = init_script,
        runfiles = ctx.runfiles(files = deps),
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

    # Run the init script
    deps = ctx.attr.module[TfModuleInfo].transitive_srcs.to_list() + tf_toolchain.runtime.deps

    return [DefaultInfo(
        executable = plan_script,
        runfiles = ctx.runfiles(files = deps),
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

    deps = ctx.attr.module[TfModuleInfo].transitive_srcs.to_list() + tf_toolchain.runtime.deps

    return [DefaultInfo(
        executable = apply_script,
        runfiles = ctx.runfiles(files = deps),
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
        "_script_template": attr.label(
            default = Label(":tf_apply.sh"),
            allow_single_file = True,
            # executable = True,
            doc = "Script to run for applying the Tf module.",
        ),
    },
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)
