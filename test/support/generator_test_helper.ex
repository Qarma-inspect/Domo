defmodule GeneratorTestHelper do
  @moduledoc false

  alias Domo.TypeEnsurerFactory.Generator

  def load_type_ensurer_module(field_spec_precond) do
    field_spec_precond
    |> generate_type_ensurer_quoted()
    |> Code.eval_quoted()
  end

  def load_type_ensurer_module_with_no_preconds(field_spec, ecto_assoc_fields \\ []) do
    field_spec
    |> ResolverTestHelper.add_empty_precond_to_spec()
    |> generate_type_ensurer_quoted(ecto_assoc_fields)
    |> Code.eval_quoted()
  end

  def generate_type_ensurer_quoted(field_spec, ecto_assoc_fields \\ []) do
    Generator.generate_one(Elixir, field_spec, ecto_assoc_fields)
  end

  def types_by_module_content(fields_spec_by_module) do
    fields_spec_by_module
    |> Enum.map(fn {module, fields} -> {module, types_content_empty_precond(fields)} end)
    |> Enum.into(%{})
  end

  defdelegate types_content_empty_precond(fields_spec), to: ResolverTestHelper, as: :add_empty_precond_to_spec
end
