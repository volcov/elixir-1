defmodule Code.Formatter do
  @moduledoc false
  import Inspect.Algebra, except: [format: 2, surround: 3, surround: 4]

  @double_quote "\""
  @double_heredoc "\"\"\""
  @single_quote "'"
  @single_heredoc "'''"
  @newlines 2
  @min_line 0
  @max_line 9_999_999
  @empty empty()

  # Operators that do not have space between operands
  @no_space_binary_operators [:..]

  # Operators that do not have newline between operands (as well as => and keywords)
  @no_newline_binary_operators [:\\, :in]

  # Left associative operators that start on the next line in case of breaks
  @left_new_line_before_binary_operators [:|>, :~>>, :<<~, :~>, :<~, :<~>, :<|>]

  # Right associative operators that start on the next line in case of breaks
  @right_new_line_before_binary_operators [:|, :when]

  # Operators that are logical cannot be mixed without parens
  @required_parens_logical_binary_operands [:||, :|||, :or, :&&, :&&&, :and]

  # Operators that always require parens on operands when they are the parent
  @required_parens_on_binary_operands [
    :|>,
    :<<<,
    :>>>,
    :<~,
    :~>,
    :<<~,
    :~>>,
    :<~>,
    :<|>,
    :^^^,
    :in,
    :++,
    :--,
    :..,
    :<>
  ]

  locals_without_parens = [
    # Special forms
    alias: 1,
    alias: 2,
    case: 2,
    cond: 1,
    import: 1,
    import: 2,
    require: 1,
    require: 2,
    for: :*,
    receive: 1,
    try: 1,
    with: :*,

    # Kernel
    def: 1,
    def: 2,
    defp: 1,
    defp: 2,
    defmacro: 1,
    defmacro: 2,
    defmacrop: 1,
    defmacrop: 2,
    defdelegate: 2,
    defexception: 1,
    defoverridable: 1,
    defstruct: 1,
    destructure: 2,
    raise: 1,
    raise: 2,
    reraise: 2,
    reraise: 3,
    if: 2,
    unless: 2,
    use: 1,
    use: 2,

    # Testing
    all: :*,
    assert: 1,
    assert: 2,
    assert_in_delta: 3,
    assert_in_delta: 4,
    assert_raise: 2,
    assert_raise: 3,
    assert_receive: 1,
    assert_receive: 2,
    assert_receive: 3,
    assert_received: 1,
    assert_received: 2,
    check: 1,
    check: 2,
    doctest: 1,
    doctest: 2,
    property: 1,
    property: 2,
    refute: 1,
    refute: 2,
    refute_in_delta: 3,
    refute_in_delta: 4,
    refute_receive: 1,
    refute_receive: 2,
    refute_receive: 3,
    refute_received: 1,
    refute_received: 2,
    setup: 1,
    setup: 2,
    test: 1,
    test: 2
  ]

  @locals_without_parens MapSet.new(locals_without_parens)

  @doc """
  Checks if two strings are equivalent.
  """
  def equivalent(string1, string2) when is_binary(string1) and is_binary(string2) do
    quoted1 = :elixir.string_to_quoted!(to_charlist(string1), 1, "nofile", [])
    quoted2 = :elixir.string_to_quoted!(to_charlist(string2), 1, "nofile", [])

    case not_equivalent(quoted1, quoted2) do
      {left, right} -> {:error, left, right}
      nil -> :ok
    end
  end

  defp not_equivalent({:__block__, _, [left]}, right) do
    not_equivalent(left, right)
  end

  defp not_equivalent(left, {:__block__, _, [right]}) do
    not_equivalent(left, right)
  end

  defp not_equivalent({:__block__, _, []}, nil) do
    nil
  end

  defp not_equivalent(nil, {:__block__, _, []}) do
    nil
  end

  defp not_equivalent([left | lefties], [right | righties]) do
    not_equivalent(left, right) || not_equivalent(lefties, righties)
  end

  defp not_equivalent({left_name, _, left_args}, {right_name, _, right_args}) do
    not_equivalent(left_name, right_name) || not_equivalent(left_args, right_args)
  end

  defp not_equivalent({left1, left2}, {right1, right2}) do
    not_equivalent(left1, right1) || not_equivalent(left2, right2)
  end

  defp not_equivalent(side, side) do
    nil
  end

  defp not_equivalent(left, right) do
    {left, right}
  end

  @doc """
  Converts `string` to an algebra document.

  Returns `{:ok, doc}` or `{:error, parser_error}`.

  See `format!/2` for the list of options.
  """
  def to_algebra(string, opts \\ []) when is_binary(string) and is_list(opts) do
    file = Keyword.get(opts, :file, "nofile")
    line = Keyword.get(opts, :line, 1)
    charlist = String.to_charlist(string)

    Process.put(:code_formatter_comments, [])
    tokenizer_options = [unescape: false, preserve_comments: &preserve_comments/5]

    with {:ok, tokens} <- :elixir.string_to_tokens(charlist, line, file, tokenizer_options),
         {:ok, forms} <- :elixir.tokens_to_quoted(tokens, file, formatter_metadata: true) do
      state =
        Process.get(:code_formatter_comments)
        |> Enum.reverse()
        |> gather_comments()
        |> state(opts)

      {doc, _} = block_to_algebra(forms, @min_line, @max_line, state)
      {:ok, doc}
    end
  after
    Process.delete(:code_formatter_comments)
  end

  @doc """
  Converts `string` to an algebra document.

  Raises if the `string` cannot be parsed.

  See `format!/2` for the list of options.
  """
  def to_algebra!(string, opts \\ []) do
    case to_algebra(string, opts) do
      {:ok, doc} ->
        doc

      {:error, {line, error, token}} ->
        :elixir_errors.parse_error(line, Keyword.get(opts, :file, "nofile"), error, token)
    end
  end

  defp state(comments, opts) do
    rename_deprecated_at =
      if version = opts[:rename_deprecated_at] do
        case Version.parse(version) do
          {:ok, parsed} ->
            parsed

          :error ->
            raise ArgumentError,
                  "invalid version #{inspect(version)} given to :rename_deprecated_at"
        end
      end

    locals_without_parens =
      opts
      |> Keyword.get(:locals_without_parens, [])
      |> MapSet.new()
      |> MapSet.union(@locals_without_parens)

    %{
      locals_without_parens: locals_without_parens,
      operand_nesting: 2,
      rename_deprecated_at: rename_deprecated_at,
      comments: comments
    }
  end

  # Code comment handling

  defp preserve_comments(line, _column, tokens, comment, rest) do
    comments = Process.get(:code_formatter_comments)
    comment = {line, {previous_eol(tokens), next_eol(rest, 0)}, format_comment(comment, [])}
    Process.put(:code_formatter_comments, [comment | comments])
  end

  defp next_eol('\s' ++ rest, count), do: next_eol(rest, count)
  defp next_eol('\t' ++ rest, count), do: next_eol(rest, count)
  defp next_eol('\n' ++ rest, count), do: next_eol(rest, count + 1)
  defp next_eol('\r\n' ++ rest, count), do: next_eol(rest, count + 1)
  defp next_eol(_, count), do: count

  defp previous_eol([{token, {_, _, count}} | _]) when token in [:eol, :",", :";"] and count > 0 do
    count
  end

  defp previous_eol([]), do: 1
  defp previous_eol(_), do: nil

  defp format_comment('##' ++ rest, acc), do: format_comment([?# | rest], [?# | acc])
  defp format_comment('#', acc), do: List.to_string(Enum.reverse(acc, '#'))
  defp format_comment('# ' ++ _ = rest, acc), do: List.to_string(Enum.reverse(acc, rest))
  defp format_comment('#' ++ rest, acc), do: List.to_string(Enum.reverse(acc, [?#, ?\s, rest]))

  # If there is a no new line before, we can't gather all followup comments.
  defp gather_comments([{line, {nil, next_eol}, doc} | comments]) do
    comment = {line, {@newlines, next_eol}, doc}
    [comment | gather_comments(comments)]
  end

  defp gather_comments([{line, {previous_eol, next_eol}, doc} | comments]) do
    {next_eol, comments, doc} = gather_followup_comments(line + 1, next_eol, comments, doc)
    comment = {line, {previous_eol, next_eol}, doc}
    [comment | gather_comments(comments)]
  end

  defp gather_comments([]) do
    []
  end

  defp gather_followup_comments(line, _, [{line, {previous_eol, next_eol}, text} | comments], doc)
       when previous_eol != nil do
    gather_followup_comments(line + 1, next_eol, comments, line(doc, text))
  end

  defp gather_followup_comments(_line, next_eol, comments, doc) do
    {next_eol, comments, doc}
  end

  # Special AST nodes from compiler feedback.

  defp quoted_to_algebra({:special, :clause_args, [args, min_line]}, _context, state) do
    {doc, state} = clause_args_to_algebra(args, min_line, state)
    {group(doc), state}
  end

  defp quoted_to_algebra({var, _meta, var_context}, _context, state) when is_atom(var_context) do
    {var |> Atom.to_string() |> string(), state}
  end

  defp quoted_to_algebra({:<<>>, meta, entries}, _context, state) do
    cond do
      entries == [] ->
        {"<<>>", state}

      not interpolated?(entries) ->
        bitstring_to_algebra(meta, entries, state)

      meta[:format] == :bin_heredoc ->
        initial = @double_heredoc |> concat(line()) |> force_break()
        interpolation_to_algebra(entries, :heredoc, state, initial, @double_heredoc)

      true ->
        interpolation_to_algebra(entries, @double_quote, state, @double_quote, @double_quote)
    end
  end

  defp quoted_to_algebra(
         {{:., _, [String, :to_charlist]}, _, [{:<<>>, meta, entries}]} = quoted,
         context,
         state
       ) do
    cond do
      not interpolated?(entries) ->
        remote_to_algebra(quoted, context, state)

      meta[:format] == :list_heredoc ->
        initial = @single_heredoc |> concat(line()) |> force_break()
        interpolation_to_algebra(entries, :heredoc, state, initial, @single_heredoc)

      true ->
        interpolation_to_algebra(entries, @single_quote, state, @single_quote, @single_quote)
    end
  end

  defp quoted_to_algebra(
         {{:., _, [:erlang, :binary_to_atom]}, _, [{:<<>>, _, entries}, :utf8]} = quoted,
         context,
         state
       ) do
    if interpolated?(entries) do
      interpolation_to_algebra(entries, @double_quote, state, ":\"", @double_quote)
    else
      remote_to_algebra(quoted, context, state)
    end
  end

  # foo[bar]
  defp quoted_to_algebra({{:., _, [Access, :get]}, meta, [target | args]}, _context, state) do
    {target_doc, state} = remote_target_to_algebra(target, state)
    {call_doc, state} = list_to_algebra(meta, args, state)
    {concat(target_doc, call_doc), state}
  end

  # %Foo{}
  # %name{foo: 1}
  # %name{bar | foo: 1}
  defp quoted_to_algebra({:%, _, [name, {:%{}, meta, args}]}, _context, state) do
    {name_doc, state} = quoted_to_algebra(name, :parens_arg, state)
    map_to_algebra(meta, name_doc, args, state)
  end

  # %{foo: 1}
  # %{foo => bar}
  # %{name | foo => bar}
  defp quoted_to_algebra({:%{}, meta, args}, _context, state) do
    map_to_algebra(meta, @empty, args, state)
  end

  # {}
  # {1, 2}
  defp quoted_to_algebra({:{}, meta, args}, _context, state) do
    tuple_to_algebra(meta, args, state)
  end

  defp quoted_to_algebra({:__block__, meta, [{left, right}]}, _context, state) do
    tuple_to_algebra(meta, [left, right], state)
  end

  defp quoted_to_algebra({:__block__, meta, [list]}, _context, state) when is_list(list) do
    case meta[:format] do
      :list_heredoc ->
        string = list |> List.to_string() |> escape_string(:heredoc)
        {@single_heredoc |> line(string) |> concat(@single_heredoc) |> force_break(), state}

      :charlist ->
        string = list |> List.to_string() |> escape_string(@single_quote)
        {@single_quote |> concat(string) |> concat(@single_quote), state}

      _other ->
        list_to_algebra(meta, list, state)
    end
  end

  defp quoted_to_algebra({:__block__, meta, [string]}, _context, state) when is_binary(string) do
    if meta[:format] == :bin_heredoc do
      string = escape_string(string, :heredoc)
      {@double_heredoc |> line(string) |> concat(@double_heredoc) |> force_break(), state}
    else
      string = escape_string(string, @double_quote)
      {@double_quote |> concat(string) |> concat(@double_quote), state}
    end
  end

  defp quoted_to_algebra({:__block__, _, [atom]}, _context, state) when is_atom(atom) do
    {atom_to_algebra(atom), state}
  end

  defp quoted_to_algebra({:__block__, meta, [integer]}, _context, state) when is_integer(integer) do
    {integer_to_algebra(Keyword.fetch!(meta, :original)), state}
  end

  defp quoted_to_algebra({:__block__, meta, [float]}, _context, state) when is_float(float) do
    {float_to_algebra(Keyword.fetch!(meta, :original)), state}
  end

  defp quoted_to_algebra(
         {:__block__, _meta, [{:unquote_splicing, _, [_] = args}]},
         context,
         state
       ) do
    {doc, state} = local_to_algebra(:unquote_splicing, args, context, state)
    {wrap_in_parens(doc), state}
  end

  defp quoted_to_algebra({:__block__, _meta, [arg]}, context, state) do
    quoted_to_algebra(arg, context, state)
  end

  defp quoted_to_algebra({:__block__, meta, _} = block, _context, state) do
    {block, state} = block_to_algebra(block, line(meta), end_line(meta), state)
    {surround("(", block, ")"), state}
  end

  defp quoted_to_algebra({:__aliases__, _meta, [head | tail]}, context, state) do
    {doc, state} =
      if is_atom(head) do
        {Atom.to_string(head), state}
      else
        quoted_to_algebra_with_parens_if_necessary(head, context, state)
      end

    {Enum.reduce(tail, doc, &concat(&2, "." <> Atom.to_string(&1))), state}
  end

  # &1
  # &local(&1)
  # &local/1
  # &Mod.remote/1
  # & &1
  # & &1 + &2
  defp quoted_to_algebra({:&, _, [arg]}, context, state) do
    capture_to_algebra(arg, context, state)
  end

  defp quoted_to_algebra({:@, meta, [arg]}, context, state) do
    module_attribute_to_algebra(meta, arg, context, state)
  end

  # not(left in right)
  # left not in right
  defp quoted_to_algebra({:not, meta, [{:in, _, [left, right]}]}, context, state) do
    binary_op_to_algebra(:in, "not in", meta, left, right, context, state)
  end

  defp quoted_to_algebra({:fn, meta, [_ | _] = clauses}, _context, state) do
    anon_fun_to_algebra(clauses, line(meta), end_line(meta), state)
  end

  defp quoted_to_algebra({fun, meta, args}, context, state) when is_atom(fun) and is_list(args) do
    with :error <- maybe_sigil_to_algebra(fun, meta, args, state),
         :error <- maybe_unary_op_to_algebra(fun, meta, args, context, state),
         :error <- maybe_binary_op_to_algebra(fun, meta, args, context, state),
         do: local_to_algebra(fun, args, context, state)
  end

  defp quoted_to_algebra({_, _, args} = quoted, context, state) when is_list(args) do
    remote_to_algebra(quoted, context, state)
  end

  # (left -> right)
  defp quoted_to_algebra([{:"->", _, _} | _] = clauses, _context, state) do
    type_fun_to_algebra(clauses, @max_line, @min_line, state)
  end

  # [keyword: :list] (inner part)
  # %{:foo => :bar} (inner part)
  defp quoted_to_algebra(list, context, state) when is_list(list) do
    args_to_algebra(list, state, &quoted_to_algebra(&1, context, &2))
  end

  # keyword: :list
  # key => value
  defp quoted_to_algebra({left, right}, context, state) do
    if keyword_key?(left) do
      {left, state} =
        case left do
          {:__block__, _, [atom]} when is_atom(atom) ->
            {atom |> Code.Identifier.inspect_as_key() |> string(), state}

          {{:., _, [:erlang, :binary_to_atom]}, _, [{:<<>>, _, entries}, :utf8]} ->
            interpolation_to_algebra(entries, @double_quote, state, "\"", "\": ")
        end

      {right, state} = quoted_to_algebra(right, context, state)
      {concat(left, right), state}
    else
      {left, state} = quoted_to_algebra(left, context, state)
      {right, state} = quoted_to_algebra(right, context, state)
      {left |> concat(" => ") |> concat(right), state}
    end
  end

  ## Blocks

  defp block_to_algebra([{:"->", _, _} | _] = type_fun, min_line, max_line, state) do
    type_fun_to_algebra(type_fun, min_line, max_line, state)
  end

  defp block_to_algebra({:__block__, _, []}, min_line, max_line, state) do
    block_args_to_algebra([], min_line, max_line, state)
  end

  defp block_to_algebra({:__block__, _, [_, _ | _] = args}, min_line, max_line, state) do
    block_args_to_algebra(args, min_line, max_line, state)
  end

  defp block_to_algebra(block, min_line, max_line, state) do
    block_args_to_algebra([block], min_line, max_line, state)
  end

  defp block_args_to_algebra(args, min_line, max_line, state) do
    quoted_to_algebra = fn {kind, meta, _} = arg, _args, doc_newlines, state ->
      doc_newlines = Keyword.get(meta, :newlines, doc_newlines)
      {doc, state} = quoted_to_algebra(arg, :block, state)
      {doc, block_next_line(kind), doc_newlines, state}
    end

    {args_docs, state} =
      quoted_to_algebra_with_comments(args, min_line, max_line, 2, state, quoted_to_algebra)

    case args_docs do
      [] -> {@empty, state}
      [line] -> {line, state}
      lines -> {lines |> Enum.reduce(&line(&2, &1)) |> force_break(), state}
    end
  end

  defp block_next_line(:@), do: @empty
  defp block_next_line(_), do: break("")

  ## Operators

  defp maybe_unary_op_to_algebra(fun, meta, args, context, state) do
    with [arg] <- args,
         {_, _} <- Code.Identifier.unary_op(fun) do
      unary_op_to_algebra(fun, meta, arg, context, state)
    else
      _ -> :error
    end
  end

  defp unary_op_to_algebra(op, _meta, arg, context, state) do
    {doc, state} = quoted_to_algebra(arg, force_many_args_or_operand(context, :operand), state)

    # not and ! are nestable, all others are not.
    wrapped_doc =
      case arg do
        {^op, _, [_]} when op in [:!, :not] -> doc
        _ -> wrap_in_parens_if_necessary(arg, doc)
      end

    # not requires a space unless the doc was wrapped in parens.
    op_string =
      if op == :not and wrapped_doc == doc do
        "not "
      else
        Atom.to_string(op)
      end

    {concat(op_string, wrapped_doc), state}
  end

  defp maybe_binary_op_to_algebra(fun, meta, args, context, state) do
    with [left, right] <- args,
         {_, _} <- Code.Identifier.binary_op(fun) do
      binary_op_to_algebra(fun, Atom.to_string(fun), meta, left, right, context, state)
    else
      _ -> :error
    end
  end

  # There are five kinds of operators.
  #
  #   1. no space binary operators, e.g. 1..2
  #   2. no newline binary operators, e.g. left in right
  #   3. strict newlines before a left precedent operator, e.g. foo |> bar |> baz
  #   4. strict newlines before a right precedent operator, e.g. foo when bar when baz
  #   5. flex newlines after the operator, e.g. foo ++ bar ++ baz
  #
  # Cases 1, 2 and 5 are handled fairly easily by relying on the
  # operator precedence and making sure nesting is applied only once.
  #
  # Cases 3 and 4 are the complex ones, as it requires passing the
  # strict or flex mode around.
  defp binary_op_to_algebra(op, op_string, meta, left_arg, right_arg, context, state) do
    %{operand_nesting: nesting} = state
    binary_op_to_algebra(op, op_string, meta, left_arg, right_arg, context, state, nil, nesting)
  end

  defp binary_op_to_algebra(
         op,
         op_string,
         meta,
         left_arg,
         right_arg,
         context,
         state,
         parent_info,
         nesting
       ) do
    op_info = Code.Identifier.binary_op(op)
    left_context = force_many_args_or_operand(context, :parens_arg)
    right_context = force_many_args_or_operand(context, :operand)

    {left, state} =
      binary_operand_to_algebra(left_arg, left_context, state, op, op_info, :left, 2)

    {right, state} =
      binary_operand_to_algebra(right_arg, right_context, state, op, op_info, :right, 0)

    doc =
      cond do
        op in @no_space_binary_operators ->
          concat(concat(left, op_string), right)

        op in @no_newline_binary_operators ->
          op_string = " " <> op_string <> " "
          concat(concat(left, op_string), right)

        op in @left_new_line_before_binary_operators ->
          op_string = op_string <> " "
          doc = glue(left, concat(op_string, nest_by_length(right, op_string)))
          doc = if Keyword.get(meta, :eol, false), do: force_break(doc), else: doc
          if op_info == parent_info, do: doc, else: group(doc)

        op in @right_new_line_before_binary_operators ->
          op_string = op_string <> " "

          # If the parent is of the same type (computed via same precedence),
          # we need to nest the left side because of the associativity.
          left =
            if op_info == parent_info do
              nest_by_length(left, op_string)
            else
              left
            end

          # If the right side is of the same type, we do the nesting above
          # on the left side later on.
          right =
            case right_arg do
              {^op, _, [_, _]} -> right
              _ -> nest_by_length(right, op_string)
            end

          doc = glue(left, concat(op_string, right))
          if is_nil(parent_info) or op_info == parent_info, do: doc, else: group(doc)

        true ->
          with_next_break_fits(next_break_fits?(right_arg), right, fn right ->
            op_string = " " <> op_string
            concat(left, group(nest(glue(op_string, group(right)), nesting, :break)))
          end)
      end

    {doc, state}
  end

  # TODO: We can remove this workaround once we remove
  # ?rearrange_uop from the parser in Elixir v2.0.
  # (! left) in right
  # (not left) in right
  defp binary_operand_to_algebra(
         {:__block__, _, [{op, meta, [arg]}]},
         context,
         state,
         :in,
         _parent_info,
         :left,
         _nesting
       )
       when op in [:not, :!] do
    {doc, state} = unary_op_to_algebra(op, meta, arg, context, state)
    {wrap_in_parens(doc), state}
  end

  defp binary_operand_to_algebra(operand, context, state, parent_op, parent_info, side, nesting) do
    with {op, meta, [left, right]} <- operand,
         op_info = Code.Identifier.binary_op(op),
         {_assoc, prec} <- op_info do
      {parent_assoc, parent_prec} = parent_info
      op_string = Atom.to_string(op)

      cond do
        # If the operator has the same precedence as the parent and is on
        # the correct side, we respect the nesting rule to avoid multiple
        # nestings.
        parent_prec == prec and parent_assoc == side ->
          binary_op_to_algebra(op, op_string, meta, left, right, context, state, op_info, nesting)

        # If the parent requires parens or the precedence is inverted or
        # it is in the wrong side, then we *need* parenthesis.
        (parent_op in @required_parens_on_binary_operands and op not in @no_space_binary_operators) or
          (op in @required_parens_logical_binary_operands and
             parent_op in @required_parens_logical_binary_operands) or parent_prec > prec or
            (parent_prec == prec and parent_assoc != side) ->
          {operand, state} =
            binary_op_to_algebra(op, op_string, meta, left, right, context, state, op_info, 2)

          {wrap_in_parens(operand), state}

        # Otherwise, we rely on precedence but also nest.
        true ->
          binary_op_to_algebra(op, op_string, meta, left, right, context, state, op_info, 2)
      end
    else
      {:&, _, [arg]} when not is_integer(arg) ->
        {doc, state} = quoted_to_algebra(operand, context, state)
        {_, prec} = Code.Identifier.unary_op(:&)
        {_, parent_prec} = parent_info

        if parent_prec < prec do
          {doc, state}
        else
          {wrap_in_parens(doc), state}
        end

      _ ->
        quoted_to_algebra(operand, context, state)
    end
  end

  ## Module attributes

  # @Foo
  # @Foo.Bar
  defp module_attribute_to_algebra(_meta, {:__aliases__, _, [_, _ | _]} = quoted, _context, state) do
    {doc, state} = quoted_to_algebra(quoted, :parens_arg, state)
    {concat(concat("@(", doc), ")"), state}
  end

  # @foo bar
  # @foo(bar)
  defp module_attribute_to_algebra(meta, {name, _, [_] = args} = expr, context, state)
       when is_atom(name) and name not in [:__block__, :__aliases__] do
    if Code.Identifier.classify(name) == :callable_local do
      {{call_doc, state}, wrap_in_parens?} =
        call_args_to_algebra(args, context, :skip_unless_many_args, false, state)

      doc =
        "@#{name}"
        |> string()
        |> concat(call_doc)

      doc = if wrap_in_parens?, do: wrap_in_parens(doc), else: doc
      {doc, state}
    else
      unary_op_to_algebra(:@, meta, expr, context, state)
    end
  end

  # @foo
  # @(foo.bar())
  defp module_attribute_to_algebra(meta, quoted, context, state) do
    unary_op_to_algebra(:@, meta, quoted, context, state)
  end

  ## Capture operator

  defp capture_to_algebra(integer, _context, state) when is_integer(integer) do
    {"&" <> Integer.to_string(integer), state}
  end

  defp capture_to_algebra(arg, context, state) do
    {doc, state} = capture_target_to_algebra(arg, context, state)

    if doc |> format_to_string() |> String.starts_with?("&") do
      {concat("& ", doc), state}
    else
      {concat("&", doc), state}
    end
  end

  defp capture_target_to_algebra(
         {:/, _, [{{:., _, [target, fun]}, _, []}, {:__block__, _, [arity]}]},
         _context,
         state
       )
       when is_atom(fun) and is_integer(arity) do
    {target_doc, state} = remote_target_to_algebra(target, state)
    fun = remote_fun_to_algebra(target, fun, arity, state)
    {target_doc |> nest(1) |> concat(string(".#{fun}/#{arity}")), state}
  end

  defp capture_target_to_algebra(
         {:/, _, [{name, _, var_context}, {:__block__, _, [arity]}]},
         _context,
         state
       )
       when is_atom(name) and is_atom(var_context) and is_integer(arity) do
    {string("#{name}/#{arity}"), state}
  end

  defp capture_target_to_algebra({op, _, [_, _]} = arg, context, state) when is_atom(op) do
    {doc, state} = quoted_to_algebra(arg, context, state)

    case Code.Identifier.binary_op(op) do
      {_, _} -> {wrap_in_parens(doc), state}
      _ -> {doc, state}
    end
  end

  defp capture_target_to_algebra(arg, context, state) do
    quoted_to_algebra(arg, context, state)
  end

  ## Calls (local, remote and anonymous)

  # expression.{arguments}
  defp remote_to_algebra({{:., _, [target, :{}]}, _, args}, _context, state) do
    {target_doc, state} = remote_target_to_algebra(target, state)
    {call_doc, state} = tuple_to_algebra([], args, state)
    {concat(concat(target_doc, "."), call_doc), state}
  end

  # expression.(arguments)
  defp remote_to_algebra({{:., _, [target]}, _, args}, context, state) do
    {target_doc, state} = remote_target_to_algebra(target, state)

    {{call_doc, state}, wrap_in_parens?} =
      call_args_to_algebra(args, context, :skip_if_do_end, true, state)

    doc = concat(concat(target_doc, "."), call_doc)
    doc = if wrap_in_parens?, do: wrap_in_parens(doc), else: doc
    {doc, state}
  end

  # Mod.function()
  # var.function
  defp remote_to_algebra({{:., _, [target, fun]}, _, []}, _context, state) when is_atom(fun) do
    {target_doc, state} = remote_target_to_algebra(target, state)
    fun = remote_fun_to_algebra(target, fun, 0, state)

    if remote_target_is_a_module?(target) do
      {target_doc |> concat(".") |> concat(string(fun)) |> concat("()"), state}
    else
      {target_doc |> concat(".") |> concat(string(fun)), state}
    end
  end

  # expression.function(arguments)
  defp remote_to_algebra({{:., _, [target, fun]}, _, args}, context, state) when is_atom(fun) do
    {target_doc, state} = remote_target_to_algebra(target, state)
    fun = remote_fun_to_algebra(target, fun, length(args), state)

    {{call_doc, state}, wrap_in_parens?} =
      call_args_to_algebra(args, context, :skip_if_do_end, true, state)

    doc = concat(concat(target_doc, "."), concat(string(fun), call_doc))
    doc = if wrap_in_parens?, do: wrap_in_parens(doc), else: doc
    {doc, state}
  end

  # call(call)(arguments)
  defp remote_to_algebra({target, _, args}, context, state) do
    {target_doc, state} = quoted_to_algebra(target, :no_parens_arg, state)

    {{call_doc, state}, wrap_in_parens?} =
      call_args_to_algebra(args, context, :required, true, state)

    doc = concat(target_doc, call_doc)
    doc = if wrap_in_parens?, do: wrap_in_parens(doc), else: doc
    {doc, state}
  end

  defp remote_target_is_a_module?(target) do
    case target do
      {:__MODULE__, _, context} when is_atom(context) -> true
      {:__block__, _, [atom]} when is_atom(atom) -> true
      {:__aliases__, _, _} -> true
      _ -> false
    end
  end

  defp remote_fun_to_algebra(target, fun, arity, state) do
    %{rename_deprecated_at: since} = state

    atom_target =
      case since && target do
        {:__aliases__, _, [alias | _] = aliases} when is_atom(alias) ->
          Module.concat(aliases)

        {:__block__, _, [atom]} when is_atom(atom) ->
          atom

        _ ->
          nil
      end

    with {fun, requirement} <- deprecated(atom_target, fun, arity),
         true <- Version.match?(since, requirement) do
      fun
    else
      _ -> Code.Identifier.inspect_as_function(fun)
    end
  end

  # We can only rename functions in the same module because
  # introducing a new module may wrong due to aliases.
  defp deprecated(Enum, :partition, 2), do: {"split_with", "~> 1.4"}
  defp deprecated(_, _, _), do: :error

  defp remote_target_to_algebra({:fn, _, [_ | _]} = quoted, state) do
    # This change is not semantically required but for beautification.
    {doc, state} = quoted_to_algebra(quoted, :no_parens_arg, state)
    {wrap_in_parens(doc), state}
  end

  defp remote_target_to_algebra(quoted, state) do
    quoted_to_algebra_with_parens_if_necessary(quoted, :no_parens_arg, state)
  end

  # function(arguments)
  defp local_to_algebra(fun, args, context, state) when is_atom(fun) do
    skip_parens =
      if skip_parens?(fun, args, state), do: :skip_unless_many_args, else: :skip_if_do_end

    {{call_doc, state}, wrap_in_parens?} =
      call_args_to_algebra(args, context, skip_parens, true, state)

    doc =
      fun
      |> Atom.to_string()
      |> string()
      |> concat(call_doc)

    doc = if wrap_in_parens?, do: wrap_in_parens(doc), else: doc
    {doc, state}
  end

  # parens may one of:
  #
  #   * :skip_unless_many_args - skips parens unless we are the argument context
  #   * :skip_if_do_end - skip parens if we are do-end
  #   * :required - never skip parens
  #
  defp call_args_to_algebra([], _context, _parens, _list_to_keyword?, state) do
    {{"()", state}, false}
  end

  defp call_args_to_algebra(args, context, parens, list_to_keyword?, state) do
    {args, last} = split_last(args)

    if blocks = do_end_blocks(last) do
      {call_doc, state} =
        case args do
          [] ->
            {@empty, state}

          _ ->
            {args, last} = split_last(args)
            no_parens? = parens != :required
            call_args_to_algebra_without_blocks(args, last, no_parens?, list_to_keyword?, state)
        end

      {blocks_doc, state} = do_end_blocks_to_algebra(blocks, state)
      call_doc = call_doc |> space(blocks_doc) |> line("end") |> force_break()
      {{call_doc, state}, context in [:no_parens_arg, :no_parens_one_arg]}
    else
      no_parens? =
        parens == :skip_unless_many_args and
          context in [:block, :operand, :no_parens_one_arg, :parens_one_arg]

      res = call_args_to_algebra_without_blocks(args, last, no_parens?, list_to_keyword?, state)
      {res, false}
    end
  end

  defp call_args_to_algebra_without_blocks(left, right, skip_parens?, list_to_keyword?, state) do
    multiple_generators? = multiple_generators?([right | left])
    {keyword?, right} = last_arg_to_keyword(right, list_to_keyword?)

    context =
      if left == [] and not keyword? do
        if skip_parens?, do: :no_parens_one_arg, else: :parens_one_arg
      else
        if skip_parens?, do: :no_parens_arg, else: :parens_arg
      end

    if left != [] and keyword? and skip_parens? and not multiple_generators? do
      call_args_to_algebra_with_no_parens_keywords(left, right, context, state)
    else
      {left, right} =
        if keyword? do
          {keyword_left, keyword_right} = split_last(right)
          {left ++ keyword_left, keyword_right}
        else
          {left, right}
        end

      {left_doc, state} = args_to_algebra(left, state, &quoted_to_algebra(&1, context, &2))
      {right_doc, state} = quoted_to_algebra(right, context, state)

      doc =
        with_next_break_fits(next_break_fits?(right), right_doc, fn right_doc ->
          args_doc =
            if left == [] do
              right_doc
            else
              glue(concat(left_doc, ","), right_doc)
            end

          args_doc =
            if multiple_generators? do
              force_break(args_doc)
            else
              args_doc
            end

          if skip_parens? do
            " "
            |> concat(nest(args_doc, :cursor, :break))
            |> group()
          else
            surround("(", args_doc, ")", :break)
          end
        end)

      {doc, state}
    end
  end

  defp call_args_to_algebra_with_no_parens_keywords(left, right, context, state) do
    {left_doc, state} = args_to_algebra(left, state, &quoted_to_algebra(&1, context, &2))
    {right_doc, state} = quoted_to_algebra(right, context, state)
    right_doc = break(" ") |> concat(right_doc) |> group(:inherit)

    doc =
      with_next_break_fits(true, right_doc, fn right_doc ->
        args_doc = concat(concat(left_doc, ","), right_doc)

        " "
        |> concat(nest(args_doc, :cursor, :break))
        |> nest(2)
        |> group()
      end)

    {doc, state}
  end

  defp skip_parens?(fun, args, %{locals_without_parens: locals_without_parens}) do
    length = length(args)

    length > 0 and
      Enum.any?(locals_without_parens, fn {key, val} ->
        key == fun and (val == :* or val == length)
      end)
  end

  defp multiple_generators?(args) do
    Enum.count(args, &match?({:<-, _, [_, _]}, &1)) >= 2
  end

  defp do_end_blocks([{{:__block__, meta, [:do]}, _} | _] = blocks) do
    if meta[:format] == :block do
      blocks
      |> Enum.map(fn {{:__block__, meta, [key]}, value} -> {key, line(meta), value} end)
      |> do_end_blocks_with_range(end_line(meta))
    end
  end

  defp do_end_blocks(_) do
    nil
  end

  defp do_end_blocks_with_range([{key1, line1, value1}, {_, line2, _} = h | t], end_line) do
    [{key1, line1, line2, value1} | do_end_blocks_with_range([h | t], end_line)]
  end

  defp do_end_blocks_with_range([{key, line, value}], end_line) do
    [{key, line, end_line, value}]
  end

  defp do_end_blocks_to_algebra([{:do, line, end_line, value} | blocks], state) do
    {acc, state} = do_end_block_to_algebra(:do, line, end_line, value, state)

    Enum.reduce(blocks, {acc, state}, fn {key, line, end_line, value}, {acc, state} ->
      {doc, state} = do_end_block_to_algebra(key, line, end_line, value, state)
      {line(acc, doc), state}
    end)
  end

  defp do_end_block_to_algebra(key, line, end_line, value, state) do
    key_doc = Atom.to_string(key)

    case clauses_to_algebra(value, line, end_line, state) do
      {@empty, state} -> {key_doc, state}
      {value_doc, state} -> {key_doc |> line(value_doc) |> nest(2), state}
    end
  end

  ## Interpolation

  defp interpolated?(entries) do
    Enum.all?(entries, fn
      {:::, _, [{{:., _, [Kernel, :to_string]}, _, [_]}, {:binary, _, _}]} -> true
      entry when is_binary(entry) -> true
      _ -> false
    end)
  end

  defp interpolation_to_algebra([entry | entries], escape, state, acc, last) when is_binary(entry) do
    acc = concat(acc, escape_string(entry, escape))
    interpolation_to_algebra(entries, escape, state, acc, last)
  end

  defp interpolation_to_algebra([entry | entries], escape, state, acc, last) do
    {:::, _, [{{:., _, [Kernel, :to_string]}, meta, [quoted]}, {:binary, _, _}]} = entry
    {doc, state} = block_to_algebra(quoted, line(meta), end_line(meta), state)
    doc = surround("\#{", doc, "}")
    interpolation_to_algebra(entries, escape, state, concat(acc, doc), last)
  end

  defp interpolation_to_algebra([], _escape, state, acc, last) do
    {concat(acc, last), state}
  end

  ## Sigils

  defp maybe_sigil_to_algebra(fun, meta, args, state) do
    case {Atom.to_string(fun), args} do
      {<<"sigil_", name>>, [{:<<>>, _, entries}, modifiers]} ->
        opening_terminator = Keyword.fetch!(meta, :terminator)
        acc = <<?~, name, opening_terminator::binary>>

        if opening_terminator in [@double_heredoc, @single_heredoc] do
          acc = force_break(concat(acc, line()))
          closing_terminator = concat(opening_terminator, List.to_string(modifiers))
          interpolation_to_algebra(entries, :heredoc, state, acc, closing_terminator)
        else
          escape = closing_sigil_terminator(opening_terminator)
          closing_terminator = concat(escape, List.to_string(modifiers))
          interpolation_to_algebra(entries, escape, state, acc, closing_terminator)
        end

      _ ->
        :error
    end
  end

  defp closing_sigil_terminator("("), do: ")"
  defp closing_sigil_terminator("["), do: "]"
  defp closing_sigil_terminator("{"), do: "}"
  defp closing_sigil_terminator("<"), do: ">"
  defp closing_sigil_terminator(other) when other in ["\"", "'", "|", "/"], do: other

  ## Bitstrings

  defp bitstring_to_algebra(meta, args, state) do
    last = length(args) - 1

    {args_doc, state} =
      args
      |> Enum.with_index()
      |> args_to_algebra_with_comments(meta, state, &bitstring_segment_to_algebra(&1, &2, last))

    {surround("<<", args_doc, ">>"), state}
  end

  defp bitstring_segment_to_algebra({{:::, _, [segment, spec]}, i}, state, last) do
    {doc, state} = quoted_to_algebra(segment, :parens_arg, state)
    {spec, state} = bitstring_spec_to_algebra(spec, state)
    doc = concat(concat(doc, "::"), wrap_in_parens_if_inspected_atom(spec))
    {bitstring_wrap_parens(doc, i, last), state}
  end

  defp bitstring_segment_to_algebra({segment, i}, state, last) do
    {doc, state} = quoted_to_algebra(segment, :parens_arg, state)
    {bitstring_wrap_parens(doc, i, last), state}
  end

  defp bitstring_spec_to_algebra({op, _, [left, right]}, state) when op in [:-, :*] do
    {left, state} = bitstring_spec_to_algebra(left, state)
    {right, state} = quoted_to_algebra_with_parens_if_necessary(right, :parens_arg, state)
    {concat(concat(left, Atom.to_string(op)), right), state}
  end

  defp bitstring_spec_to_algebra(spec, state) do
    quoted_to_algebra_with_parens_if_necessary(spec, :parens_arg, state)
  end

  defp bitstring_wrap_parens(doc, i, last) do
    if i == 0 or i == last do
      string = format_to_string(doc)

      if (i == 0 and String.starts_with?(string, "<<")) or
           (i == last and String.ends_with?(string, ">>")) do
        wrap_in_parens(doc)
      else
        doc
      end
    else
      doc
    end
  end

  ## Literals

  defp list_to_algebra(meta, args, state) do
    {args_doc, state} =
      args_to_algebra_with_comments(args, meta, state, &quoted_to_algebra(&1, :parens_arg, &2))

    {surround("[", args_doc, "]"), state}
  end

  defp map_to_algebra(meta, name_doc, [{:|, _, [left, right]}], state) do
    {left_doc, state} = quoted_to_algebra(left, :parens_arg, state)

    {right_doc, state} =
      args_to_algebra_with_comments(right, meta, state, &quoted_to_algebra(&1, :parens_arg, &2))

    args_doc = group(glue(left_doc, concat("| ", nest(right_doc, 2))))
    name_doc = "%" |> concat(name_doc) |> concat("{")
    {surround(name_doc, args_doc, "}"), state}
  end

  defp map_to_algebra(meta, name_doc, args, state) do
    {args_doc, state} =
      args_to_algebra_with_comments(args, meta, state, &quoted_to_algebra(&1, :parens_arg, &2))

    name_doc = "%" |> concat(name_doc) |> concat("{")
    {surround(name_doc, args_doc, "}"), state}
  end

  defp tuple_to_algebra(meta, args, state) do
    {args_doc, state} =
      args_to_algebra_with_comments(args, meta, state, &quoted_to_algebra(&1, :parens_arg, &2))

    {surround("{", args_doc, "}"), state}
  end

  defp atom_to_algebra(atom) when atom in [nil, true, false] do
    Atom.to_string(atom)
  end

  defp atom_to_algebra(atom) do
    string = Atom.to_string(atom)

    iodata =
      case Code.Identifier.classify(atom) do
        type when type in [:callable_local, :callable_operator, :not_callable] ->
          [?:, string]

        _ ->
          [?:, ?", String.replace(string, "\"", "\\\""), ?"]
      end

    iodata |> IO.iodata_to_binary() |> string()
  end

  defp integer_to_algebra(text) do
    case text do
      [?0, ?x | rest] ->
        "0x" <> String.upcase(List.to_string(rest))

      [?0, base | _rest] = digits when base in [?b, ?o] ->
        List.to_string(digits)

      [?? | _rest] = char ->
        List.to_string(char)

      decimal ->
        List.to_string(insert_underscores(decimal))
    end
  end

  defp float_to_algebra(text) do
    {int_part, [?. | decimal_part]} = Enum.split_while(text, &(&1 != ?.))

    decimal_part =
      decimal_part
      |> List.to_string()
      |> String.downcase()

    List.to_string(insert_underscores(int_part)) <> "." <> decimal_part
  end

  defp insert_underscores(digits) do
    if length(digits) >= 6 do
      digits
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.intersperse('_')
      |> List.flatten()
      |> Enum.reverse()
    else
      digits
    end
  end

  defp escape_string(string, :heredoc) do
    heredoc_to_algebra(String.split(string, "\n"))
  end

  defp escape_string(string, escape) when is_binary(escape) do
    string
    |> String.replace(escape, "\\" <> escape)
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.map(&string/1)
    |> Enum.reduce(&concat(&1, concat(nest(line(), :reset), &2)))
  end

  defp heredoc_to_algebra([string]) do
    string(string)
  end

  defp heredoc_to_algebra([string, ""]) do
    string
    |> string()
    |> concat(line())
  end

  defp heredoc_to_algebra([string, "" | rest]) do
    string
    |> string()
    |> concat(nest(line(), :reset))
    |> line(heredoc_to_algebra(rest))
  end

  defp heredoc_to_algebra([string | rest]) do
    line(string(string), heredoc_to_algebra(rest))
  end

  defp args_to_algebra_with_comments(args, meta, state, fun) do
    min_line = line(meta)
    max_line = end_line(meta)

    arg_to_algebra = fn arg, args, newlines, state ->
      {doc, state} = fun.(arg, state)
      doc = if args == [], do: doc, else: concat(doc, ",")
      {doc, @empty, newlines, state}
    end

    {args_docs, new_state} =
      quoted_to_algebra_with_comments(args, min_line, max_line, 1, state, arg_to_algebra)

    cond do
      args_docs == [] ->
        {@empty, new_state}

      Keyword.get(meta, :eol, false) or force_container_break?(state, new_state) ->
        {args_docs |> Enum.reduce(&line(&2, &1)) |> force_break(), new_state}

      true ->
        {args_docs |> Enum.reduce(&glue(&2, &1)), new_state}
    end
  end

  defp force_container_break?(%{comments: comments}, %{comments: comments}), do: false
  defp force_container_break?(_, _), do: true

  ## Anonymous functions

  # fn -> block end
  defp anon_fun_to_algebra([{:"->", meta, [[], body]}] = clauses, _min_line, max_line, state) do
    min_line = line(meta)
    {body_doc, state} = block_to_algebra(body, min_line, max_line, state)

    doc =
      "fn ->"
      |> glue(body_doc)
      |> nest(2)
      |> glue("end")
      |> maybe_force_clauses(clauses)
      |> group()

    {doc, state}
  end

  # fn x -> y end
  # fn x ->
  #   y
  # end
  defp anon_fun_to_algebra([{:"->", meta, [args, body]}] = clauses, _min_line, max_line, state) do
    min_line = line(meta)
    {args_doc, state} = clause_args_to_algebra(args, min_line, state)
    {body_doc, state} = block_to_algebra(body, min_line, max_line, state)

    doc =
      "fn "
      |> concat(group(args_doc))
      |> concat(" ->")
      |> nest(1)
      |> glue(body_doc)
      |> nest(2)
      |> glue("end")
      |> maybe_force_clauses(clauses)
      |> group()

    {doc, state}
  end

  # fn
  #   args1 ->
  #     block1
  #   args2 ->
  #     block2
  # end
  defp anon_fun_to_algebra(clauses, min_line, max_line, state) do
    {clauses_doc, state} = clauses_to_algebra(clauses, min_line, max_line, state)
    {"fn" |> line(clauses_doc) |> nest(2) |> line("end") |> force_break(), state}
  end

  ## Type functions

  # (() -> block)
  defp type_fun_to_algebra([{:"->", meta, [[], body]}] = clauses, _min_line, max_line, state) do
    min_line = line(meta)
    {body_doc, state} = block_to_algebra(body, min_line, max_line, state)

    doc =
      "(() -> "
      |> concat(nest(body_doc, :cursor))
      |> concat(")")
      |> maybe_force_clauses(clauses)
      |> group()

    {doc, state}
  end

  # (x -> y)
  # (x ->
  #    y)
  defp type_fun_to_algebra([{:"->", meta, [args, body]}] = clauses, _min_line, max_line, state) do
    min_line = line(meta)
    {args_doc, state} = clause_args_to_algebra(args, min_line, state)
    {body_doc, state} = block_to_algebra(body, min_line, max_line, state)

    clause_doc =
      " ->"
      |> glue(body_doc)
      |> nest(2)

    doc =
      args_doc
      |> group()
      |> concat(clause_doc)
      |> wrap_in_parens()
      |> maybe_force_clauses(clauses)
      |> group()

    {doc, state}
  end

  # (
  #   args1 ->
  #     block1
  #   args2 ->
  #     block2
  # )
  defp type_fun_to_algebra(clauses, min_line, max_line, state) do
    {clauses_doc, state} = clauses_to_algebra(clauses, min_line, max_line, state)
    {"(" |> line(clauses_doc) |> nest(2) |> line(")") |> force_break(), state}
  end

  ## Clauses

  defp maybe_force_clauses(doc, clauses) do
    if Enum.any?(clauses, fn {:"->", meta, _} -> Keyword.get(meta, :eol, false) end) do
      force_break(doc)
    else
      doc
    end
  end

  defp clauses_to_algebra([{:"->", _, _} | _] = clauses, min_line, max_line, state) do
    [clause | clauses] = add_max_line_to_last_clause(clauses, max_line)
    {clause_doc, state} = clause_to_algebra(clause, min_line, state)

    {clauses_doc, state} =
      Enum.reduce(clauses, {clause_doc, state}, fn clause, {doc_acc, state_acc} ->
        {clause_doc, state_acc} = clause_to_algebra(clause, min_line, state_acc)

        doc_acc =
          doc_acc
          |> concat(maybe_empty_line())
          |> line(clause_doc)

        {doc_acc, state_acc}
      end)

    {clauses_doc |> maybe_force_clauses([clause | clauses]) |> group(), state}
  end

  defp clauses_to_algebra(other, min_line, max_line, state) do
    case block_to_algebra(other, min_line, max_line, state) do
      {@empty, state} -> {@empty, state}
      {doc, state} -> {group(doc), state}
    end
  end

  defp clause_to_algebra({:"->", meta, [[], body]}, _min_line, state) do
    {body_doc, state} = block_to_algebra(body, line(meta), end_line(meta), state)
    {"() ->" |> glue(body_doc) |> nest(2), state}
  end

  defp clause_to_algebra({:"->", meta, [args, body]}, min_line, state) do
    %{operand_nesting: nesting} = state

    state = %{state | operand_nesting: nesting + 2}
    {args_doc, state} = clause_args_to_algebra(args, min_line, state)

    state = %{state | operand_nesting: nesting}
    {body_doc, state} = block_to_algebra(body, min_line, end_line(meta), state)
    {concat(group(args_doc), " ->" |> glue(body_doc) |> nest(2)), state}
  end

  defp add_max_line_to_last_clause([{op, meta, args}], max_line) do
    [{op, [end_line: max_line] ++ meta, args}]
  end

  defp add_max_line_to_last_clause([clause | clauses], max_line) do
    [clause | add_max_line_to_last_clause(clauses, max_line)]
  end

  # fn a, b, c when d -> e end
  defp clause_args_to_algebra([{:when, meta, args}], min_line, state) do
    {args, right} = split_last(args)
    left = {:special, :clause_args, [args, min_line]}
    binary_op_to_algebra(:when, "when", meta, left, right, :no_parens_arg, state)
  end

  # fn a, b, c -> e end
  defp clause_args_to_algebra([], _min_line, state) do
    {"()", state}
  end

  defp clause_args_to_algebra(args, min_line, state) do
    arg_to_algebra = &quoted_to_algebra(&1, :no_parens_arg, &2)
    args_to_algebra_with_comments(args, [line: min_line], state, arg_to_algebra)
  end

  ## Quoted helpers for comments

  defp quoted_to_algebra_with_comments(args, min_line, max_line, newlines, state, fun) do
    {pre_comments, state} =
      get_and_update_in(state.comments, fn comments ->
        Enum.split_while(comments, fn {line, _, _} -> line <= min_line end)
      end)

    {docs, state} = each_quoted_to_algebra_with_comments(args, [], max_line, newlines, state, fun)
    {docs, update_in(state.comments, &(pre_comments ++ &1))}
  end

  defp each_quoted_to_algebra_with_comments([arg | args], acc, max_line, newlines, state, fun) do
    %{comments: comments} = state
    {doc_start, doc_end} = traverse_line(arg, {@max_line, @min_line})

    {doc_newlines, acc, comments} = extract_comments_before(doc_start, newlines, acc, comments)

    {doc, next_line, doc_newlines, state} =
      fun.(arg, args, doc_newlines, %{state | comments: comments})

    %{comments: comments} = state

    {doc_newlines, acc, comments} =
      extract_comments_trailing(doc_start, doc_end, doc_newlines, acc, comments)

    acc = [{doc, next_line, doc_newlines} | acc]
    state = %{state | comments: comments}
    each_quoted_to_algebra_with_comments(args, acc, max_line, newlines, state, fun)
  end

  defp each_quoted_to_algebra_with_comments([], acc, max_line, _newlines, state, _fun) do
    %{comments: comments} = state

    {current, comments} = Enum.split_with(comments, fn {line, _, _} -> line < max_line end)

    extra = for {_, {previous, _}, doc} <- current, do: {doc, @empty, previous}
    args_docs = merge_algebra_with_comments(Enum.reverse(acc, extra), @empty)
    {args_docs, %{state | comments: comments}}
  end

  defp extract_comments_before(max, _, acc, [{line, _, _} = comment | comments]) when line < max do
    {_, {previous, next}, doc} = comment
    acc = [{doc, @empty, previous} | acc]
    extract_comments_before(max, next, acc, comments)
  end

  defp extract_comments_before(_max, newlines, acc, comments) do
    {newlines, acc, comments}
  end

  defp extract_comments_trailing(min, max, newlines, acc, [{line, _, doc_comment} | comments])
       when line >= min and line <= max do
    acc = [{doc_comment, @empty, newlines} | acc]
    extract_comments_trailing(min, max, 1, acc, comments)
  end

  defp extract_comments_trailing(_min, _max, newlines, acc, comments) do
    {newlines, acc, comments}
  end

  defp traverse_line({expr, meta, args}, {min, max}) do
    acc =
      case Keyword.fetch(meta, :line) do
        {:ok, line} -> {min(line, min), max(line, max)}
        :error -> {min, max}
      end

    traverse_line(args, traverse_line(expr, acc))
  end

  defp traverse_line({left, right}, acc) do
    traverse_line(right, traverse_line(left, acc))
  end

  defp traverse_line(args, acc) when is_list(args) do
    Enum.reduce(args, acc, &traverse_line/2)
  end

  defp traverse_line(_, acc) do
    acc
  end

  # Below are the rules for line rendering in the formatter:
  #
  #   1. respect the user's choice
  #   2. and add empty lines around expressions that take multiple lines
  #      (except for module attributes)
  #   3. empty lines are collapsed as to not exceed more than one
  #
  defp merge_algebra_with_comments([{doc, next_line, _newlines} | docs], left) do
    right = next_line_separator(docs, next_line)

    doc =
      if left != @empty do
        concat(left, doc)
      else
        doc
      end

    doc =
      if docs != [] and right != @empty do
        concat(doc, concat(collapse_lines(2), right))
      else
        doc
      end

    [group(doc) | merge_algebra_with_comments(docs, right)]
  end

  defp merge_algebra_with_comments([], _) do
    []
  end

  ## Quoted helpers

  defp force_many_args_or_operand(:no_parens_one_arg, _choice), do: :no_parens_arg
  defp force_many_args_or_operand(:parens_one_arg, _choice), do: :parens_arg
  defp force_many_args_or_operand(:no_parens_arg, _choice), do: :no_parens_arg
  defp force_many_args_or_operand(:parens_arg, _choice), do: :parens_arg
  defp force_many_args_or_operand(:operand, choice), do: choice
  defp force_many_args_or_operand(:block, choice), do: choice

  defp quoted_to_algebra_with_parens_if_necessary(ast, context, state) do
    {doc, state} = quoted_to_algebra(ast, context, state)
    {wrap_in_parens_if_necessary(ast, doc), state}
  end

  # TODO: We can remove this workaround once we remove
  # ?rearrange_uop from the parser in Elixir v2.0.
  defp wrap_in_parens_if_necessary({:__block__, _, [expr]}, doc) do
    wrap_in_parens_if_necessary(expr, doc)
  end

  defp wrap_in_parens_if_necessary(quoted, doc) do
    if operator?(quoted) and not module_attribute_read?(quoted) and not integer_capture?(quoted) do
      wrap_in_parens(doc)
    else
      doc
    end
  end

  defp wrap_in_parens_if_inspected_atom(":" <> _ = doc) do
    "(" <> doc <> ")"
  end

  defp wrap_in_parens_if_inspected_atom(doc) do
    doc
  end

  defp wrap_in_parens(doc) do
    concat(concat("(", nest(doc, :cursor)), ")")
  end

  defp args_to_algebra([], state, _fun) do
    {@empty, state}
  end

  defp args_to_algebra([arg | args], state, fun) do
    Enum.reduce(args, fun.(arg, state), fn arg, {doc_acc, state_acc} ->
      {arg_doc, state_acc} = fun.(arg, state_acc)
      {glue(concat(doc_acc, ","), arg_doc), state_acc}
    end)
  end

  defp next_line_separator([{_doc, _next_line, newlines} | _], next_line) do
    if newlines >= @newlines, do: line(), else: next_line
  end

  defp next_line_separator([], _) do
    line()
  end

  defp module_attribute_read?({:@, _, [{var, _, var_context}]})
       when is_atom(var) and is_atom(var_context) do
    Code.Identifier.classify(var) == :callable_local
  end

  defp module_attribute_read?(_), do: false

  defp integer_capture?({:&, _, [integer]}) when is_integer(integer), do: true
  defp integer_capture?(_), do: false

  defp operator?(quoted) do
    unary_operator?(quoted) or binary_operator?(quoted)
  end

  defp binary_operator?(quoted) do
    case quoted do
      {op, _, [_, _]} when is_atom(op) ->
        Code.Identifier.binary_op(op) != :error

      _ ->
        false
    end
  end

  defp unary_operator?(quoted) do
    case quoted do
      {op, _, [_]} when is_atom(op) ->
        Code.Identifier.unary_op(op) != :error

      _ ->
        false
    end
  end

  defp with_next_break_fits(condition, doc, fun) do
    if condition do
      doc
      |> next_break_fits(:enabled)
      |> fun.()
      |> next_break_fits(:disabled)
    else
      fun.(doc)
    end
  end

  defp next_break_fits?({:<<>>, meta, [_ | _] = entries}) do
    meta[:format] == :bin_heredoc or not interpolated?(entries)
  end

  defp next_break_fits?({{:., _, [String, :to_charlist]}, _, [{:<<>>, meta, [_ | _]}]}) do
    meta[:format] == :list_heredoc
  end

  defp next_break_fits?({:{}, _, _}) do
    true
  end

  defp next_break_fits?({:__block__, _meta, [{_, _}]}) do
    true
  end

  defp next_break_fits?({:__block__, meta, [string]}) when is_binary(string) do
    meta[:format] == :bin_heredoc
  end

  defp next_break_fits?({:__block__, meta, [list]}) when is_list(list) do
    meta[:format] != :charlist
  end

  defp next_break_fits?({form, _, [_ | _]}) when form in [:fn, :%{}, :%] do
    true
  end

  defp next_break_fits?({fun, meta, args}) when is_atom(fun) and is_list(args) do
    meta[:terminator] in [@double_heredoc, @single_heredoc] and
      fun |> Atom.to_string() |> String.starts_with?("sigil_")
  end

  defp next_break_fits?({{:__block__, _, [atom]}, expr}) when is_atom(atom) do
    next_break_fits?(expr)
  end

  defp next_break_fits?(_) do
    false
  end

  defp last_arg_to_keyword([_ | _] = arg, _list_to_keyword?) do
    {keyword?(arg), arg}
  end

  defp last_arg_to_keyword({:__block__, _, [[_ | _] = arg]} = block, true) do
    if keyword?(arg), do: {true, arg}, else: {false, block}
  end

  defp last_arg_to_keyword(arg, _list_to_keyword?) do
    {false, arg}
  end

  defp keyword?([{key, _} | list]) do
    keyword_key?(key) and keyword?(list)
  end

  defp keyword?(rest) do
    rest == []
  end

  defp keyword_key?({:__block__, meta, [_]}) do
    meta[:format] == :keyword
  end

  defp keyword_key?({{:., _, [:erlang, :binary_to_atom]}, _, [{:<<>>, meta, _}, :utf8]}) do
    meta[:format] == :keyword
  end

  defp keyword_key?(_) do
    false
  end

  defp line(meta) do
    Keyword.get(meta, :line, @max_line)
  end

  defp end_line(meta) do
    Keyword.get(meta, :end_line, @min_line)
  end

  ## Algebra helpers

  defp format_to_string(doc) do
    doc |> Inspect.Algebra.format(:infinity) |> IO.iodata_to_binary()
  end

  defp maybe_empty_line() do
    nest(break(""), :reset)
  end

  defp surround(left, doc, right, nest \\ :always) do
    if doc == @empty do
      concat(left, right)
    else
      group(glue(nest(glue(left, "", doc), 2, nest), "", right))
    end
  end

  defp nest_by_length(doc, string) do
    nest(doc, String.length(string))
  end

  defp split_last(list) do
    {left, [right]} = Enum.split(list, -1)
    {left, right}
  end
end
