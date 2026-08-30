// Structure types and fields use stable names so extensions can share them.
ldpl_structure_PERSON SHARED;

void POPULATE()
{
    SHARED.VAR_NAME = "From C++";
    SHARED.VAR_AGE = 7;
}
