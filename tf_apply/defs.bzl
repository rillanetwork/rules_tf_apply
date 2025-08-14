"""
This module provides macros and rules for initializing, planning, and applying Terraform modules using rules_tf and rules_tf_apply.
"""

load("@rules_tf//tf:def.bzl", _tf_module = "tf_module")
load("@rules_tf_apply//tf_apply/rules:defs.bzl", _tf_apply = "tf_apply", _tf_init = "tf_init", _tf_plan = "tf_plan")

tf_apply = _tf_apply
tf_init = _tf_init
tf_plan = _tf_plan

def tf_module(name, **kwargs):
    """
    Macro to create a Terraform module and apply rules for initialization, planning, and applying.

    Args:
        name: The name of the Terraform module.
        **kwargs: Additional attributes for the module.
    """
    _tf_module(name = name, **kwargs)

    tf_init(
        name = "init",
        module = native.package_relative_label(name),
    )

    tf_plan(
        name = "plan",
        module = native.package_relative_label(name),
    )

    tf_apply(
        name = "apply",
        module = native.package_relative_label(name),
    )
