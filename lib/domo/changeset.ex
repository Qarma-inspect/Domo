defmodule Domo.Changeset do
  @moduledoc """
  Validation functions for [Ecto.Changeset](https://hexdocs.pm/ecto/Ecto.Changeset.html#module-validations-and-constraints).

  The `Ecto` schema changes can be validated to conform to types in `t()`
  and to fulfill appropriate preconditions.

      defmodule User do
        use Ecto.Schema
        use Domo, skip_defaults: true

        import Ecto.Changeset
        import Domo.Changeset

        schema "users" do
          field :first_name, :string
          field :last_name, :string
          field :age, :integer
        end

        @type t :: %__MODULE__{
          first_name :: String.t() | nil,
          last_name :: String.t(),
          age :: age()
        }

        @type age :: pos_integer()
        precond age: &validate_age/1

        @max_age 150
        defp validate_age(age) when age < @max_age, do: :ok
        defp validate_age(_age), do: {:error, "age should be in 1..\#{@max_age}"}

        def changeset(user, attrs) do
          user
          |> cast(attrs, typed_fields())
          |> validate_required(required_fields())
          |> validate_type(maybe_filter_precond_errors: true)
        end
      end

  The `skip_defaults: true` option disables the validation of defaults
  to match to `t()` type at compile time. That is useful because any Ecto schema
  has all fields set to `nil` by default.

  `typed_fields/1` and `required_fields/1` are added automatically to
  the current module by using Domo.

  The `first_name` field is not required to have a value in the changeset
  because it has `nil` as one of the possible types defined.

  `validate_type/2` function automatically adds type ensurance errors to the
  changeset. The `maybe_filter_precond_errors: true` option enables
  the filtering of the precondition error message for `:age` field.
  That error is ready to be communicated to the user.
  """

  alias Domo.Raises

  @doc """
  Validates changeset changes to conform to the schema's `t()` type and fulfill
  preconditions.

  The function performs validations within the call to Ecto's
  `validate_change/3`. In case there's at least one error, the list of errors
  will be appended to the `:errors` field of the changeset
  and the `:valid?` flag will be set to `false`.

  The function raises a `RuntimeError` if some of the changed fields are not defined
  in the `t()` type.

  ## Options

    * `:fields` - the list of changed fields that should be validated
    * `:maybe_filter_precond_errors` - when set to `true` the function returns
      first error received from the precondition function for each field.
      In case if no precondition function is defined for the field type,
      then autogenerated error will be returned.
    * `:take_error_fun` - function returning most relevant error from the list
      of errors for a field. Works when `maybe_filter_precond_errors: true`
      is given. It can be useful in cases when several precondition errors
      are returned for the given field.
      By default it's `fn list -> List.first(list) end`.

  ## Examples

      %User{}
      |> cast(%{last_name: "Doe", age: 21}, [:last_name, :age])
      |> validate_type()
  """
  def validate_type(changeset, opts \\ [])

  def validate_type(%{data: %schema{}} = changeset, opts) do
    validate_schemaless_type(changeset, schema, opts)
  end

  def validate_type(_changeset, _opts) do
    Raises.raise_no_schema_module()
  end

  @doc """
  Validates schemaless changeset changes to conform to the schema's `t()` type
  and fulfill preconditions.

  Similar to `validate_type/2`.

  `struct` is a module name providing `t()` type and preconditions for changes
  validation.

  ## Examples

      {%{}, %{first_name: :string, last_name: :string, age: :integer}}
      |> cast(%{last_name: "Doe", age: 21}, [:last_name, :age])
      |> validate_schemaless_type(User)
  """
  if Code.ensure_loaded?(Ecto.Changeset) do
    def validate_schemaless_type(changeset, struct, opts \\ []) when is_atom(struct) do
      alias Domo.TypeEnsurerFactory

      unless TypeEnsurerFactory.has_type_ensurer?(struct) do
        Raises.raise_no_type_ensurer_for_schema_module(struct)
      end

      {opts_fields, opts} = Keyword.pop(opts, :fields)
      type_ensurer = TypeEnsurerFactory.type_ensurer(struct)

      if opts_fields do
        all_fields_set = MapSet.new(type_ensurer.fields(:typed_no_meta_with_any))

        extra_fields =
          opts_fields
          |> MapSet.new()
          |> MapSet.difference(all_fields_set)

        unless Enum.empty?(extra_fields) do
          Raises.raise_not_defined_fields(extra_fields |> MapSet.to_list() |> Enum.sort(), struct)
        end
      end

      fields = opts_fields || type_ensurer.fields(:typed_no_meta_no_any)

      do_validate(changeset, type_ensurer, fields, opts)
    end

    defp do_validate(changeset, type_ensurer, fields, opts) do
      maybe_filter_precond_errors = Keyword.get(opts, :maybe_filter_precond_errors, false)
      take_error_fun = Keyword.get(opts, :take_error_fun, &List.first/1)

      changeset
      |> do_validate_field_types(type_ensurer, fields, maybe_filter_precond_errors, take_error_fun)
      |> maybe_validate(&do_validate_t_precondition(&1, type_ensurer, maybe_filter_precond_errors, take_error_fun))
    end

    defp maybe_validate(%{valid?: false} = changeset, _fun), do: changeset
    defp maybe_validate(changeset, fun), do: fun.(changeset)

    defp do_validate_field_types(changeset, type_ensurer, fields, maybe_filter_precond_errors, take_error_fun) do
      Enum.reduce(fields, changeset, fn field, changeset ->
        Ecto.Changeset.validate_change(changeset, field, fn field, value ->
          do_validate_field(type_ensurer, field, value, maybe_filter_precond_errors, take_error_fun)
        end)
      end)
    end

    defp do_validate_field(type_ensurer, field, value, maybe_filter_precond_errors, take_error_fun) do
      alias Domo.ErrorBuilder

      case type_ensurer.ensure_field_type({field, value}, []) do
        :ok ->
          []

        {:error, _message} = error ->
          {key, message} = ErrorBuilder.pretty_error_by_key(error, maybe_filter_precond_errors)

          message =
            if maybe_filter_precond_errors do
              take_error_fun.(message)
            else
              message
            end

          [{key, message}]
      end
    end

    defp do_validate_t_precondition(changeset, type_ensurer, maybe_filter_precond_errors, take_error_fun) do
      alias Domo.ErrorBuilder

      changed_data = Ecto.Changeset.apply_changes(changeset)

      case type_ensurer.t_precondition(changed_data) do
        :ok ->
          changeset

        {:error, _message} = error ->
          {key, message} = ErrorBuilder.pretty_error_by_key(error, maybe_filter_precond_errors)

          message =
            if maybe_filter_precond_errors do
              take_error_fun.(message)
            else
              message
            end

          Ecto.Changeset.add_error(changeset, key, message)
      end
    end
  else
    def validate_schemaless_type(_changeset, _struct, _opts \\ []) do
      Raises.raise_no_ecto_module()
    end
  end
end
