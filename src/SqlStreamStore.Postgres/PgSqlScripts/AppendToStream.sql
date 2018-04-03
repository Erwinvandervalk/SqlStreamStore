CREATE OR REPLACE FUNCTION public.append_to_stream(
  _stream_id           CHAR(42),
  _stream_id_original  VARCHAR(1000),
  _metadata_stream_id  CHAR(42),
  _expected_version    INT,
  _created_utc         TIMESTAMP,
  _new_stream_messages public.new_stream_message [])
  RETURNS TABLE(
    current_version  INT,
    current_position BIGINT,
    json_data        VARCHAR
  ) AS $F$
DECLARE
  _current_version             INT;
  _current_position            BIGINT;
  _stream_id_internal          INT;
  _metadata_stream_id_internal INT;
  _current_message             public.new_stream_message;
  _stream_created              INT;
  _message_id_record           RECORD;
  _message_id_cursor           REFCURSOR;
  _message_ids                 UUID [] = '{}' :: UUID [];
BEGIN

  SELECT id_internal
  INTO _metadata_stream_id_internal
  FROM public.streams
  WHERE id = _metadata_stream_id;

  IF _expected_version = -2 /* ExpectedVersion.Any */
  THEN

    INSERT INTO public.streams (id, id_original)
      SELECT
        _stream_id,
        _stream_id_original
    ON CONFLICT DO NOTHING;

  ELSIF _expected_version = -1 /* ExpectedVersion.NoStream */
    THEN

      INSERT INTO public.streams (id, id_original)
        SELECT
          _stream_id,
          _stream_id_original
      ON CONFLICT DO NOTHING;

      GET DIAGNOSTICS _stream_created = ROW_COUNT;

      IF _stream_created = 0 AND cardinality(_new_stream_messages) > 0
      THEN
        _message_id_cursor = (
          SELECT *
          FROM public.read(_stream_id, cardinality(_new_stream_messages), 0, true, false)
          OFFSET 1
        );

        FETCH FROM _message_id_cursor
        INTO _message_id_record;

        WHILE FOUND LOOP
          _message_ids = array_append(_message_ids, _message_id_record.message_id);

          FETCH FROM _message_id_cursor
          INTO _message_id_record;
        END LOOP;

        IF _message_ids <> (
          SELECT ARRAY(
              SELECT n.message_id
              FROM UNNEST(_new_stream_messages) n
          ))
        THEN
          RAISE EXCEPTION 'WrongExpectedVersion';
        ELSE
          SELECT
            version,
            position,
            id_internal
          INTO _current_version, _current_position, _stream_id_internal
          FROM public.streams
          WHERE public.streams.id = _stream_id;

          RETURN QUERY
          SELECT
            _current_version,
            _current_position,
            public.messages.json_data
          FROM public.messages
          WHERE public.messages.stream_id_internal = _metadata_stream_id_internal
                OR _metadata_stream_id_internal IS NULL
          ORDER BY position DESC
          LIMIT 1;
          RETURN;
        END IF;
      END IF;
  END IF;

  SELECT
    version,
    position,
    id_internal
  INTO _current_version, _current_position, _stream_id_internal
  FROM public.streams
  WHERE public.streams.id = _stream_id;

  IF _expected_version >= 0 AND (_stream_id_internal IS NULL OR _current_version != _expected_version)
  THEN
    RAISE EXCEPTION 'WrongExpectedVersion';
  END IF;

  IF cardinality(_new_stream_messages) > 0
  THEN
    INSERT INTO public.messages (
      message_id,
      stream_id_internal,
      stream_version,
      created_utc,
      type,
      json_data,
      json_metadata
    )
      SELECT
        m.message_id,
        _stream_id_internal,
        _current_version + (row_number()
        over ()) :: int,
        _created_utc,
        m.type,
        m.json_data,
        m.json_metadata
      FROM unnest(_new_stream_messages) m;
    SELECT
      COALESCE(public.messages.position, -1),
      COALESCE(public.messages.stream_version, -1)
    INTO _current_position, _current_version
    FROM public.messages
    WHERE public.messages.stream_id_internal = _stream_id_internal
    ORDER BY public.messages.position DESC
    LIMIT 1;

    UPDATE public.streams
    SET "version" = _current_version, "position" = _current_position
    WHERE id_internal = _stream_id_internal;

    RETURN QUERY
    SELECT
      _current_version,
      _current_position,
      public.messages.json_data
    FROM public.messages
    WHERE public.messages.stream_id_internal = _metadata_stream_id_internal
          OR _metadata_stream_id_internal IS NULL
    ORDER BY position DESC
    LIMIT 1;

  ELSE
    RETURN QUERY
    SELECT
      -1,
      -1 :: BIGINT,
      NULL :: VARCHAR;

  END IF;

END;

$F$
LANGUAGE 'plpgsql';