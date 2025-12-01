"""
This module provides macros and rules for initializing, planning, and applying Terraform modules using rules_tf and rules_tf_apply.
"""

load("@rules_tf_apply//tf_apply/rules:defs.bzl", _tf_apply = "tf_apply", _tf_backend = "tf_backend", _tf_init = "tf_init", _tf_plan = "tf_plan", _tf_vars = "tf_vars")

tf_apply = _tf_apply
tf_init = _tf_init
tf_plan = _tf_plan
tf_vars = _tf_vars
tf_backend = _tf_backend

def tf_root_module(
        name,
        module,
        backend,
        tfvars = {},
        tfvars_deps = {},
        tags = [],
        visibility = ["//visibility:private"]):
    """
    Macro to create a Terraform module and apply rules for initialization, planning, and applying.

    Args:
        name: The name of the Terraform module.
        **kwargs: Additional attributes for the module.
    """

    # Remove tfvars_deps from kwargs to avoid passing it to _tf_module

    tf_vars(
        name = "{}.tfvars".format(name),
        name_prefix = name,
        module = module,
        tfvars_deps = tfvars_deps,
        tfvars = tfvars,
        visibility = visibility,
    )

    if backend:
        # Backend is an object with one key, which is the backend type
        if len(backend.keys()) > 1:
            fail("backend attribute must have exactly one backend type")

        backend_type = list(backend.keys())[0]
        backend_config = backend[backend_type]

        tf_backend(
            name = "{}.backend".format(name),
            name_prefix = name,
            type = backend_type,
            config = backend_config,
            visibility = visibility,
        )

    tf_init(
        name = "{}.init".format(name),
        module = module,
        tfvars = ":{}.tfvars".format(name),
        backend = ":{}.backend".format(name),
        tags = tags,
        visibility = visibility,
    )

    tf_plan(
        name = "{}.plan".format(name),
        module = module,
        tfvars = ":{}.tfvars".format(name),
        backend = ":{}.backend".format(name),
        tags = tags,
        visibility = visibility,
    )

    tf_apply(
        name = "{}.apply".format(name),
        module = module,
        tfvars = ":{}.tfvars".format(name),
        backend = ":{}.backend".format(name),
        tags = tags,
        visibility = visibility,
    )
